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

  Future<void> remove(String id) async {
    await _storage.bookshelf.delete(id);
    notifyListeners();
  }

  bool isInShelf(String id) {
    return _storage.bookshelf.containsKey(id);
  }
}
