import '../models/bookmark.dart';
import '../services/storage_service.dart';

/// Repository for managing bookmarks.
class BookmarkRepository {
  final StorageService _storage;

  BookmarkRepository(this._storage);

  List<Bookmark> getAll() {
    return _storage.bookmarks.values
        .map((v) => Bookmark.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  List<Bookmark> getByBookId(String bookId) {
    return _storage.bookmarks.values
        .map((v) => Bookmark.fromJson(Map<String, dynamic>.from(v as Map)))
        .where((b) => b.bookId == bookId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<Bookmark> add(Bookmark bookmark) async {
    await _storage.bookmarks.put(bookmark.id, bookmark.toJson());
    return bookmark;
  }

  Future<void> remove(String id) async {
    await _storage.bookmarks.delete(id);
  }
}
