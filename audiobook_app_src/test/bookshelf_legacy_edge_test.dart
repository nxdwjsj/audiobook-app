import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:audiobook_app/models/bookshelf_book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/bookshelf_repository.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// B1（章节拆表）的**旧数据**边界：
///
/// 惰性迁移模型下，旧记录的内嵌 `chapters` 是唯一副本（独立 box 为空）。
/// 任何「只写元信息、不带 chapters」的写操作都**不能**把内嵌章节抹掉，
/// 否则旧用户会在「拖动排序 / 编辑信息」后丢掉整本书的章节。
void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('lingyun_legacy_edge');
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

  List<Map<String, dynamic>> embeddedChapters(int n) => List.generate(
        n,
        (i) => Chapter(
          filename: 'c$i.mp3',
          title: '第 $i 集',
          duration: const Duration(minutes: 1),
          fileId: 'fid$i',
          driveType: DriveType.quark,
        ).toJson(),
      );

  /// 旧版本 App 写入的记录：chapters 内嵌在 bookshelf 记录里，独立 box 为空。
  Map<String, dynamic> legacyRecord(String id, int count) => {
        'id': id,
        'title': '旧书$id',
        'addedAt': DateTime(2024, 1, 1).toIso8601String(),
        'driveType': 'quark',
        'drivePath': '/有声书/旧书$id',
        'chapters': embeddedChapters(count),
      };

  bool recordHasEmbeddedChapters(String id) {
    final rec =
        Hive.box(StorageService.bookshelfBox).get(id) as Map<dynamic, dynamic>;
    final ch = rec['chapters'];
    return ch is List && ch.isNotEmpty;
  }

  test('前置：旧数据内嵌章节可被读出（独立 box 为空）', () async {
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    final repo = newRepo();
    expect(Hive.box(StorageService.chaptersBox).containsKey('legacy'), isFalse);
    expect(repo.getChapters('legacy'), hasLength(3));
    expect(repo.getById('legacy')!.chapters, hasLength(3));
  });

  test('reorder（拖动排序）不得让旧数据丢章节', () async {
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 3));
    final repo = newRepo();
    final books = repo.getAll();
    expect(books.single.chapters, hasLength(3), reason: '旧记录 getAll 应带内嵌章节');

    // 书架页拖动排序 → repo.reorder(getAll())
    await repo.reorder(books);

    // 用全新 repo（空 LRU）读取，排除内存缓存掩盖
    final fresh = newRepo();
    expect(
      fresh.getChapters('legacy'),
      hasLength(3),
      reason: '排序后旧数据章节被 toJson 抹掉且未迁移 → 数据丢失',
    );
    // 进一步确认内嵌字段仍在
    expect(recordHasEmbeddedChapters('legacy'), isTrue,
        reason: 'reorder 不应剥离旧记录的内嵌 chapters');
  });

  test('update（编辑信息，不带 chapters）不得让旧数据丢章节', () async {
    await Hive.box(StorageService.bookshelfBox)
        .put('legacy', legacyRecord('legacy', 4));
    final repo = newRepo();
    final loaded = repo.getById('legacy')!;

    // 模拟编辑信息页：只带元信息、chapters 为 null
    await repo.update(BookshelfBook(
      id: loaded.id,
      title: loaded.title,
      author: '新作者',
      coverUrl: loaded.coverUrl,
      chapterCount: loaded.chapterCount,
      driveType: loaded.driveType,
      drivePath: loaded.drivePath,
    ));

    final fresh = newRepo();
    expect(
      fresh.getChapters('legacy'),
      hasLength(4),
      reason: '编辑信息后旧数据章节丢失',
    );
    expect(fresh.getById('legacy')!.author, '新作者');
  });
}
