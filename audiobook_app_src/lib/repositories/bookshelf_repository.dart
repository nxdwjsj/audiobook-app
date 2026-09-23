import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../services/storage_service.dart';

/// Repository for managing bookshelf books.
///
/// Extends [ChangeNotifier] so UI pages watching this repo rebuild
/// whenever the shelf changes (add / remove).
///
/// ## 章节存储（PERF-01）
///
/// 章节不再内嵌在 `bookshelf` box 的书记录里，而是按 bookId 存在独立的
/// `chapters` box。这样：
/// - 改一次的封面/作者只写一条约 300B 的记录，不再把上千条章节整段重写；
/// - `getAll()` 不必再反序列化章节。
///
/// 迁移是**惰性 + 双读**的：[getChapters] 依次查「内存 LRU → chapters box →
/// 书记录里内嵌的旧字段」。老数据（章节还内嵌着）不改也能正常读；
/// 历史记录里的内嵌字段不做清理，因此回滚旧版本 App 依然可读。
class BookshelfRepository extends ChangeNotifier {
  /// 章节内存缓存条数上限（LRU）。
  /// 章节列表可达上千条，缓存不宜过大；5 本足以覆盖「书架滚动 + 进详情」的局部性。
  static const int chapterCacheLimit = 5;

  final StorageService _storage;

  BookshelfRepository(this._storage);

  /// `getAll()` 结果缓存。书架页每次重建都会调用它，全量 fromJson + sort 的
  /// 成本随书数线性增长，这里缓存到下一次写操作为止。
  List<BookshelfBook>? _allCache;

  /// 章节 LRU：LinkedHashMap 尾部为最近使用。
  final LinkedHashMap<String, List<Chapter>> _chapterCache =
      LinkedHashMap<String, List<Chapter>>();

  /// 书架全部书籍（已按手动顺序 / 加入时间排序）。
  ///
  /// 返回的是缓存的**副本**（元素本身不可变），调用方可以放心排序/过滤，
  /// 不会污染缓存。**注意：返回的对象不含章节**，需要章节请用 [getChapters]
  /// 或 [getById]。
  List<BookshelfBook> getAll() {
    final cached = _allCache;
    if (cached != null) return List<BookshelfBook>.of(cached);

    final books = _storage.bookshelf.values
        .map((v) => BookshelfBook.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort(_compareBooks);
    _allCache = books;
    return List<BookshelfBook>.of(books);
  }

  /// 手动排序优先（长按拖动后写入），否则按加入时间倒序。
  static int _compareBooks(BookshelfBook a, BookshelfBook b) {
    if (a.sortOrder != null || b.sortOrder != null) {
      final sa = a.sortOrder ?? 1 << 30;
      final sb = b.sortOrder ?? 1 << 30;
      return sa.compareTo(sb);
    }
    return b.addedAt.compareTo(a.addedAt);
  }

  /// 按 id 取书，**并补上章节**（保持章节拆表前的调用方行为不变）。
  BookshelfBook? getById(String id) {
    final v = _storage.bookshelf.get(id);
    if (v == null) return null;
    final book = BookshelfBook.fromJson(Map<String, dynamic>.from(v as Map));
    return book.withChapters(getChapters(id));
  }

  /// 读取某本书的章节列表（惰性迁移的双读入口）。
  ///
  /// 查找顺序：内存 LRU → 独立 `chapters` box → 书记录里内嵌的旧 `chapters` 字段。
  /// 命中后写入 LRU；查不到返回空列表（不返回 null，调用方无需判空）。
  ///
  /// ## 已知边界（刻意不加迁移时间戳，接受此代价）
  ///
  /// 因为「优先读新 box、且旧内嵌字段不清理」，存在一个很窄的时序：
  /// **回滚到旧版本 → 在旧版本里重新列目录把章节写回内嵌字段 → 再升级回新版**，
  /// 此时 `chapters` box 里仍留着回滚前那份章节，会被优先读到，于是可能显示
  /// 回滚前的旧章节。概率极低，且**自愈**：在新版里重新列一次目录即覆盖
  /// `chapters` box，或直接移除该书重加。
  ///
  /// 之所以不引入时间戳/版本号来彻底消除：它会把「惰性迁移 + 旧字段保留」这个
  /// 简单模型复杂化，收益不抵成本（已由 team-lead 裁决保持现状）。
  List<Chapter> getChapters(String bookId) {
    final hit = _chapterCache.remove(bookId);
    if (hit != null) {
      _chapterCache[bookId] = hit; // LRU touch：移到队尾
      return hit;
    }
    final chapters = _readChaptersFromStores(bookId);
    _cacheChapters(bookId, chapters);
    return chapters;
  }

  List<Chapter> _readChaptersFromStores(String bookId) {
    final stored = _storage.chapters.get(bookId);
    if (stored is List) {
      return stored.map(_chapterFrom).toList();
    }
    // 回落：老数据从没写过 chapters box，章节仍在 bookshelf 记录里
    final record = _storage.bookshelf.get(bookId);
    if (record is Map) {
      final embedded = record['chapters'];
      if (embedded is List) {
        return embedded.map(_chapterFrom).toList();
      }
    }
    return const <Chapter>[];
  }

  static Chapter _chapterFrom(dynamic raw) =>
      Chapter.fromJson(Map<String, dynamic>.from(raw as Map));

  void _cacheChapters(String bookId, List<Chapter> chapters) {
    _chapterCache.remove(bookId);
    _chapterCache[bookId] = chapters;
    while (_chapterCache.length > chapterCacheLimit) {
      _chapterCache.remove(_chapterCache.keys.first); // 淘汰最久未用
    }
  }

  Future<void> add(BookshelfBook book) async {
    await _writeBook(book);
    _allCache = null;
    notifyListeners();
  }

  /// 拖动排序：按新顺序写入 sortOrder。
  /// 用 `putAll` 一次批量提交，避免 N 次独立写事务。
  ///
  /// 注意：`putAll` 写的是**整条记录**。若直接用 `toJson()`（不含 chapters）
  /// 覆盖，会把旧数据内嵌的章节抹掉。所以每本书都先生成一条「保留旧内嵌
  /// chapters」的记录，并保证所有旧数据迁移都在 `putAll` 之前做完。
  Future<void> reorder(List<BookshelfBook> books) async {
    final writes = <String, dynamic>{};
    for (var i = 0; i < books.length; i++) {
      final b = books[i];
      if (b.sortOrder == i) continue;
      // 守卫：先把旧数据的内嵌章节迁进独立 box（若尚无副本），再写元信息记录。
      await _preserveLegacyChapters(b.id);
      writes[b.id] = _recordFor(b, sortOrder: i);
    }
    if (writes.isNotEmpty) await _storage.bookshelf.putAll(writes);
    _allCache = null;
    notifyListeners();
  }

  /// 更新书籍元信息（编辑信息用）。
  ///
  /// 传入对象的 [BookshelfBook.chapters] 为 null 表示「本次不涉及章节」，
  /// 此时不会写 `chapters` box —— 编辑封面/作者不会重写上千条章节。
  Future<void> update(BookshelfBook book) async {
    await _writeBook(book);
    _allCache = null;
    notifyListeners();
  }

  /// 写一本书：元信息进 `bookshelf`，章节（若有）进独立 `chapters` box。
  ///
  /// [BookshelfBook.chapters] 为 null 时**不动** chapters box（也不回落内嵌
  /// 字段），这是消除写放大的关键。
  Future<void> _writeBook(BookshelfBook book) async {
    // 写路径守卫：先迁移旧数据的内嵌章节，避免下面这条不含 chapters 的
    // 记录把旧记录里唯一的章节副本抹掉（见 [_preserveLegacyChapters]）。
    await _preserveLegacyChapters(book.id);
    final fresh = book.chapters;
    await _storage.bookshelf.put(
      book.id,
      // 带**权威**新章节的写入（首写 / 重新列目录）时，独立 box 成为唯一真相，
      // 记录里可能过期的内嵌副本可安全清掉，消除写放大；只写元信息时则必须
      // 保留旧内嵌副本，否则会丢章节。
      _recordFor(book, keepEmbedded: fresh == null),
    );
    if (fresh != null) {
      await _storage.chapters.put(
        book.id,
        fresh.map((c) => c.toJson()).toList(),
      );
      _cacheChapters(book.id, fresh);
    }
  }

  /// 写路径守卫（PERF-01 旧数据防线，本次 P0 的主修复）。
  ///
  /// 惰性迁移下，老记录的内嵌 `chapters` 是唯一副本（独立 box 为空）。而
  /// [BookshelfBook.toJson] 不再输出 `chapters`，Hive 的 `put` 又是**整值
  /// 替换**而非字段合并 —— 于是「拖动排序 / 编辑信息」这类只写元信息的操作
  /// 会把老记录里内嵌的章节键**静默抹掉**（独立 box 又没有副本）→ 章节彻底
  /// 丢失。为此在**任何不含 chapters 的写入之前**先调用本方法：若独立 box
  /// 尚无该书的副本，就把记录里内嵌的 `chapters` 原样落进 box，使数据的存亡
  /// 与「用户是否进过详情页（是否调用过 [getChapters]）」彻底解耦。
  ///
  /// 只在 box 缺副本时迁移，命中即跳过 —— 不会每次写都重复迁移。
  Future<void> _preserveLegacyChapters(String id) async {
    if (_storage.chapters.containsKey(id)) return;
    final record = _storage.bookshelf.get(id);
    if (record is! Map) return;
    final embedded = record['chapters'];
    if (embedded is! List || embedded.isEmpty) return;
    await _storage.chapters.put(id, embedded.toList());
  }

  /// 生成要写入 `bookshelf` box 的元信息记录。
  ///
  /// [keepEmbedded] 为 true 时**保留**已有记录里内嵌的旧 `chapters` 键：B1 的
  /// 惰性迁移承诺「内嵌字段不清理 → 回滚旧版本 App 仍可读」，若用不含 chapters
  /// 的新记录整值覆盖，会打破该承诺并（独立 box 无副本时）丢章节 —— 因此采用
  /// 「新字段覆盖、旧键保留」的合并写法。
  Map<String, dynamic> _recordFor(
    BookshelfBook book, {
    int? sortOrder,
    bool keepEmbedded = true,
  }) {
    final record = book.toJson();
    if (sortOrder != null) record['sortOrder'] = sortOrder;
    if (!keepEmbedded) return record;
    final existing = _storage.bookshelf.get(book.id);
    if (existing is Map) {
      final embedded = existing['chapters'];
      if (embedded is List && embedded.isNotEmpty) {
        record['chapters'] = embedded;
      }
    }
    return record;
  }

  /// 移出书架：同时删除自定义封面文件、独立章节，避免残留孤儿数据越积越多。
  Future<void> remove(String id) async {
    await _deleteCoverFile(id);
    await _storage.bookshelf.delete(id);
    await _storage.chapters.delete(id);
    _chapterCache.remove(id);
    _allCache = null;
    notifyListeners();
  }

  /// 删除某本书的自定义封面文件（文件不存在或非本 App 目录时静默跳过）。
  Future<void> _deleteCoverFile(String id) async {
    try {
      final v = _storage.bookshelf.get(id);
      if (v == null) return;
      final book = BookshelfBook.fromJson(Map<String, dynamic>.from(v as Map));
      final path = book.localCoverPath;
      if (path == null || path.isEmpty) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[Bookshelf] 删除封面失败: $e');
    }
  }

  bool isInShelf(String id) {
    return _storage.bookshelf.containsKey(id);
  }
}
