import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:audiobook_app/models/bookshelf_book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/bookshelf_repository.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// P0 修复（写路径守卫）的**关键路径**回归。
///
/// 与 `bookshelf_legacy_edge_test.dart`（QA 的护栏）互补，这里专门覆盖三件事：
/// 1. 修在**写路径**、与「是否读过章节」解耦 —— 完全不调用 `getChapters()`
///    直接排序也不能丢章节（防止靠读取路径迁移蒙混过关）；
/// 2. 守卫**命中即跳过**：box 已有副本时不做重复迁移；
/// 3. 写放大没有回来：新书经排序 / 编辑后记录仍不含 chapters。
void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('lingyun_legacy_guard');
    Hive.init(tmp.path);
    await Hive.openBox(StorageService.bookshelfBox);
    await Hive.openBox(StorageService.chaptersBox);
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

  List<Map<String, dynamic>> embedded(int n) => List.generate(
        n,
        (i) => Chapter(
          filename: 'c$i.mp3',
          title: '第 $i 集',
          duration: const Duration(minutes: 1),
          fileId: 'fid$i',
          driveType: DriveType.quark,
        ).toJson(),
      );

  Map<String, dynamic> legacyRecord(String id, int count) => {
        'id': id,
        'title': '旧书$id',
        'addedAt': DateTime(2024, 1, 1).toIso8601String(),
        'driveType': 'quark',
        'drivePath': '/有声书/旧书$id',
        'chapters': embedded(count),
      };

  test('关键路径：完全不调用 getChapters，直接 reorder 也不丢旧章节', () async {
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));

    final repo = newRepo();
    // 模拟最坏情况：调用方对象**不带 chapters**（写路径若依赖读取侧迁移，
    // 这里就会丢数据）。用 getAll() 拿列表后把 chapters 抹成 null。
    final books =
        repo.getAll().map((b) => b.withChapters(null)).toList(growable: false);
    expect(books.single.chapters, isNull);

    // 全程不调用 getChapters()，直接排序
    await repo.reorder(books);

    // 用全新 repo（空 LRU）验证：章节必须仍在
    final fresh = newRepo();
    expect(
      fresh.getChapters('legacy'),
      hasLength(3),
      reason: '写路径守卫应保证不依赖读取侧迁移；否则未进过详情页的用户排序即丢章节',
    );
  });

  test('守卫命中即跳过：box 已有副本时不重复迁移（不覆盖）', () async {
    // 记录里内嵌 3 条，box 里另放 5 条哨兵：若守卫「命中即跳过」，
    // 排序后 box 应仍是这 5 条哨兵（未被内嵌的 3 条覆盖）。
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    final sentinel = embedded(5);
    await Hive.box(StorageService.chaptersBox).put('legacy', sentinel);

    final repo = newRepo();
    await repo.reorder(repo.getAll());

    final stored = Hive.box(StorageService.chaptersBox).get('legacy') as List;
    expect(stored, hasLength(5), reason: 'box 已有副本，守卫不应重复迁移覆盖');
    expect((stored.first as Map)['fileId'], 'fid0');
  });

  test('新书经 reorder：章节不丢、记录不含 chapters（写放大没回来）', () async {
    final repo = newRepo();
    await repo.add(BookshelfBook(
      id: 'b1',
      title: '三体',
      chapterCount: 1000,
      chapters: List.generate(
        1000,
        (i) => Chapter(
          filename: 'c$i.mp3',
          title: '第 $i 集',
          duration: const Duration(minutes: 1),
          fileId: 'fid$i',
        ),
      ),
      driveType: DriveType.quark,
    ));

    await repo.reorder([repo.getAll().single]);

    final record =
        Hive.box(StorageService.bookshelfBox).get('b1') as Map<dynamic, dynamic>;
    expect(record.containsKey('chapters'), isFalse,
        reason: '新书记录本就不含 chapters，排序不得把章节又塞回记录');
    expect(repo.getChapters('b1'), hasLength(1000));
  });

  test('新书经 update（只改元信息）：记录不含 chapters、章节不丢', () async {
    final repo = newRepo();
    await repo.add(BookshelfBook(
      id: 'b1',
      title: '三体',
      chapterCount: 500,
      chapters: List.generate(
        500,
        (i) => Chapter(
          filename: 'c$i.mp3',
          title: '第 $i 集',
          duration: const Duration(minutes: 1),
          fileId: 'fid$i',
        ),
      ),
      driveType: DriveType.quark,
    ));
    final loaded = repo.getById('b1')!;

    await repo.update(BookshelfBook(
      id: loaded.id,
      title: loaded.title,
      author: '新作者',
      chapterCount: loaded.chapterCount,
    ));

    final record =
        Hive.box(StorageService.bookshelfBox).get('b1') as Map<dynamic, dynamic>;
    expect(record.containsKey('chapters'), isFalse);
    // 记录体量不随章节数增长（写放大已消除）
    expect(jsonEncode(record).length, lessThan(1000));
    expect(repo.getChapters('b1'), hasLength(500));
  });

  test('自愈转场：带权威新章节写入后，内嵌副本被清、box 收敛为唯一真相', () async {
    // 旧记录：内嵌 3 条，box 为空
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    final repo = newRepo();

    // 模拟「重新列目录」：拿到旧书 → 换上权威的新章节（5 条）→ 写回
    final loaded = repo.getById('legacy')!;
    final fresh = List.generate(
      5,
      (i) => Chapter(
        filename: 'new$i.mp3',
        title: '新第 $i 集',
        duration: const Duration(minutes: 1),
        fileId: 'new$i',
        driveType: DriveType.quark,
      ),
    );
    await repo.update(loaded.withChapters(fresh));

    // ① 记录里的内嵌 chapters 键已被清掉：不再有两份可能分叉的副本
    final record = Hive.box(StorageService.bookshelfBox).get('legacy') as Map;
    expect(record.containsKey('chapters'), isFalse,
        reason: '权威新章节写入后必须清掉旧内嵌副本，避免双副本长期分叉');
    // ② box 里是新的那一份，读回也是新的
    final stored = Hive.box(StorageService.chaptersBox).get('legacy') as List;
    expect(stored, hasLength(5));
    expect((stored.first as Map)['fileId'], 'new0');
    expect(repo.getChapters('legacy'), hasLength(5));
  });

  test('remove 仍清掉独立 box（守卫没把它带坏）', () async {
    final repo = newRepo();
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    // 触发一次迁移，确保 box 有副本
    await repo.reorder(repo.getAll());
    expect(Hive.box(StorageService.chaptersBox).containsKey('legacy'), isTrue);

    await repo.remove('legacy');

    expect(Hive.box(StorageService.bookshelfBox).containsKey('legacy'), isFalse);
    expect(Hive.box(StorageService.chaptersBox).containsKey('legacy'), isFalse);
    expect(repo.getChapters('legacy'), isEmpty);
  });
}
