import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/bookshelf_book.dart';
import '../services/storage_service.dart';

/// Repository for managing bookshelf books.
///
/// Extends [ChangeNotifier] so UI pages watching this repo rebuild
/// whenever the shelf changes (add / remove).
class BookshelfRepository extends ChangeNotifier {
  final StorageService _storage;

  BookshelfRepository(this._storage);

  List<BookshelfBook> getAll() {
    final books = _storage.bookshelf.values
        .map((v) => BookshelfBook.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) {
        // 手动排序优先（长按拖动后写入），否则按加入时间倒序
        if (a.sortOrder != null || b.sortOrder != null) {
          final sa = a.sortOrder ?? 1 << 30;
          final sb = b.sortOrder ?? 1 << 30;
          return sa.compareTo(sb);
        }
        return b.addedAt.compareTo(a.addedAt);
      });
    return books;
  }

  BookshelfBook? getById(String id) {
    final v = _storage.bookshelf.get(id);
    if (v == null) return null;
    return BookshelfBook.fromJson(Map<String, dynamic>.from(v as Map));
  }

  Future<void> add(BookshelfBook book) async {
    await _storage.bookshelf.put(book.id, book.toJson());
    notifyListeners();
  }

  /// 拖动排序：按新顺序写入 sortOrder。
  Future<void> reorder(List<BookshelfBook> books) async {
    for (var i = 0; i < books.length; i++) {
      final b = books[i];
      if (b.sortOrder == i) continue;
      await _storage.bookshelf.put(b.id,
          {...b.toJson(), 'sortOrder': i});
    }
    notifyListeners();
  }

  /// 更新书籍元信息（编辑信息用）。
  Future<void> update(BookshelfBook book) async {
    await _storage.bookshelf.put(book.id, book.toJson());
    notifyListeners();
  }

  /// 移出书架：同时删除自定义封面文件，避免残留孤儿文件越积越多。
  Future<void> remove(String id) async {
    await _deleteCoverFile(id);
    await _storage.bookshelf.delete(id);
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
