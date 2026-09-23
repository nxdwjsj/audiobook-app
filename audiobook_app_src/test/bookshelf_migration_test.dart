import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:audiobook_app/models/bookshelf_book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/bookshelf_repository.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 章节拆表（PERF-01）的迁移与双读回归。
/// 用真实 Hive（临时目录）跑，覆盖「旧数据内嵌 → 新数据独立 box」的兼容路径。
void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('lingyun_shelf_test');
    Hive.init(tmp.path);
    await Hive.openBox(StorageService.bookshelfBox);
    await Hive.openBox(StorageService.chaptersBox);
    // 纯 Dart 测试不便走 StorageService.init()（依赖 Flutter binding），
    // 直接放行 box 访问。
    StorageService.markReadyForTesting();
  });

  setUp(() async {
    await Hive.box(StorageService.bookshelfBox).clear();
    await Hive.box(StorageService.chaptersBox).clear();
  });

  tearDownAll(() async {
    StorageService.resetReadyForTesting();
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  BookshelfRepository newRepo() => BookshelfRepository(StorageService());

  List<Chapter> chaptersOf(int n) => List.generate(
        n,
        (i) => Chapter(
          filename: 'c$i.mp3',
          title: '第 $i 集',
          duration: const Duration(minutes: 1),
          fileId: 'fid$i',
        ),
      );

  BookshelfBook book({
    String id = 'b1',
    String title = '三体',
    List<Chapter>? chapters,
  }) =>
      BookshelfBook(
        id: id,
        title: title,
        chapterCount: chapters?.length ?? 1,
        chapters: chapters,
        driveType: DriveType.quark,
        drivePath: '/有声书/$title',
      );

  /// 模拟「旧版本 App 写入的记录」：chapters 内嵌在书记录里。
  Map<String, dynamic> legacyRecord(String id, int chapterCount) => {
        'id': id,
        'title': '旧书$id',
        'addedAt': DateTime(2024, 1, 1).toIso8601String(),
        'driveType': 'quark',
        'chapters': chaptersOf(chapterCount).map((c) => c.toJson()).toList(),
      };

  // ---------------------------------------------------------------
  // 必测三条：① 旧数据能读 ② 新数据 toJson 不含 chapters ③ LRU 回落
  // ---------------------------------------------------------------

  test('① 旧数据（chapters 内嵌）仍能正确读出', () async {
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    final repo = newRepo();

    // 独立 box 里没有这条 → 必须回落到内嵌字段
    expect(
      Hive.box(StorageService.chaptersBox).containsKey('legacy'),
      isFalse,
    );
    final chapters = repo.getChapters('legacy');
    expect(chapters, hasLength(3));
    expect(chapters.first.title, '第 0 集');
    expect(chapters.last.fileId, 'fid2');

    // getById 也要带上章节（详情页/历史续播/编辑页依赖）
    final loaded = repo.getById('legacy');
    expect(loaded, isNotNull);
    expect(loaded!.chapters, hasLength(3));
    expect(loaded.title, '旧书legacy');
  });

  test('② 新数据写入后 toJson 与书记录都不再含 chapters，章节落到独立 box',
      () async {
    final repo = newRepo();
    final b = book(chapters: chaptersOf(5));
    await repo.add(b);

    // 模型层：序列化产物不含 chapters
    expect(b.toJson().containsKey('chapters'), isFalse);
    // 持久化层：bookshelf 记录不含 chapters
    final record =
        Hive.box(StorageService.bookshelfBox).get('b1') as Map<dynamic, dynamic>;
    expect(record.containsKey('chapters'), isFalse);
    // 章节确实搬到了独立 box
    final stored = Hive.box(StorageService.chaptersBox).get('b1') as List;
    expect(stored, hasLength(5));
    expect((stored.first as Map)['fileId'], 'fid0');
    // 且仍能原样读回
    expect(repo.getChapters('b1'), hasLength(5));
  });

  test('③ LRU 未命中（含被淘汰）时能回落内嵌旧字段', () async {
    final box = Hive.box(StorageService.bookshelfBox);
    await box.put('old0', legacyRecord('old0', 2));
    final repo = newRepo();

    // 先读一次，写入 LRU
    expect(repo.getChapters('old0'), hasLength(2));

    // 再读入足够多不同的书，把 old0 挤出 LRU
    for (var i = 0; i < BookshelfRepository.chapterCacheLimit + 1; i++) {
      await box.put('fill$i', legacyRecord('fill$i', 1));
      repo.getChapters('fill$i');
    }

    // old0 已不在缓存，且独立 box 里从来没有它 → 必须回落内嵌字段
    expect(Hive.box(StorageService.chaptersBox).containsKey('old0'), isFalse);
    expect(repo.getChapters('old0'), hasLength(2));
  });

  // ---------------------------------------------------------------
  // 写放大消除与缓存行为
  // ---------------------------------------------------------------

  test('元信息记录的体量不再随章节数增长（写放大已消除）', () {
    // 两本书除「章节条数」外全部字段一致：若 chapters 仍内嵌，序列化体量
    // 会相差上千条；拆表后两者应完全相同。
    BookshelfBook of(int count) => BookshelfBook(
          id: 'b1',
          title: '三体',
          chapterCount: 1000,
          chapters: chaptersOf(count),
          driveType: DriveType.quark,
          drivePath: '/有声书/三体',
        );
    final one = jsonEncode(of(1).toJson());
    final thousand = jsonEncode(of(1000).toJson());
    expect(thousand.length, one.length);
  });

  test('update 只改元信息时不重写章节，章节与独立 box 原样保留', () async {
    final repo = newRepo();
    await repo.add(book(chapters: chaptersOf(1000)));

    final loaded = repo.getById('b1')!;
    // 模拟「编辑书籍信息」：只带元信息，不带 chapters
    await repo.update(BookshelfBook(
      id: loaded.id,
      title: loaded.title,
      coverUrl: loaded.coverUrl,
      description: '改过的简介',
      chapterCount: loaded.chapterCount,
      sortOrder: loaded.sortOrder,
      localCoverPath: '/covers/x.jpg',
    ));

    final record =
        Hive.box(StorageService.bookshelfBox).get('b1') as Map<dynamic, dynamic>;
    expect(record['description'], '改过的简介');
    expect(record['localCoverPath'], '/covers/x.jpg');
    expect(record.containsKey('chapters'), isFalse);
    // 章节仍在，且未被清空
    expect(repo.getChapters('b1'), hasLength(1000));
  });

  test('reorder 批量写 sortOrder，且不影响章节', () async {
    final repo = newRepo();
    await repo.add(book(id: 'a', title: 'A', chapters: chaptersOf(3)));
    await repo.add(book(id: 'b', title: 'B', chapters: chaptersOf(4)));

    await repo.reorder([repo.getById('a')!, repo.getById('b')!]);

    final all = repo.getAll();
    expect(all.map((e) => e.id).toList(), ['a', 'b']);
    expect(all[0].sortOrder, 0);
    expect(all[1].sortOrder, 1);
    expect(repo.getChapters('a'), hasLength(3));
    expect(repo.getChapters('b'), hasLength(4));
  });

  test('getAll 命中缓存；写操作后缓存失效并重算', () async {
    final repo = newRepo();
    await repo.add(book(id: 'a', title: 'A'));
    expect(repo.getAll(), hasLength(1));

    // 绕过 repo 直接写 box：缓存未失效时 getAll 不应看到新书
    await Hive.box(StorageService.bookshelfBox)
        .put('z', legacyRecord('z', 1));
    expect(repo.getAll(), hasLength(1), reason: '应命中缓存');

    // 任一写操作后缓存失效 → 重新全量，能看到外部写入
    await repo.add(book(id: 'b', title: 'B'));
    expect(repo.getAll(), hasLength(3));
  });

  test('getAll 返回副本，调用方排序不会污染缓存', () async {
    final repo = newRepo();
    await repo.add(book(id: 'a', title: 'A'));
    await repo.add(book(id: 'b', title: 'B'));

    final first = repo.getAll();
    first.clear(); // 调用方破坏性修改
    expect(repo.getAll(), hasLength(2));
  });

  test('remove 同时清掉独立章节，不留孤儿数据', () async {
    final repo = newRepo();
    await repo.add(book(chapters: chaptersOf(3)));
    expect(Hive.box(StorageService.chaptersBox).containsKey('b1'), isTrue);

    await repo.remove('b1');

    expect(repo.getById('b1'), isNull);
    expect(Hive.box(StorageService.bookshelfBox).containsKey('b1'), isFalse);
    expect(Hive.box(StorageService.chaptersBox).containsKey('b1'), isFalse);
    expect(repo.getChapters('b1'), isEmpty);
  });

  test('章节数量不影响 getAll 的返回内容（getAll 不再带章节）', () async {
    final repo = newRepo();
    await repo.add(book(id: 'a', title: 'A', chapters: chaptersOf(500)));
    final listed = repo.getAll().single;
    // getAll() 刻意不携带章节：书架列表页只需要元信息
    expect(listed.chapters, isNull);
    expect(listed.title, 'A');
    // 需要章节时按需取，走独立 box
    expect(repo.getChapters(listed.id), hasLength(500));
  });
}
