import 'package:flutter/foundation.dart';

import '../models/playback_progress.dart';
import '../services/storage_service.dart';

/// Repository for managing playback progress.
///
/// Extends [ChangeNotifier] so bookshelf items rebuild when progress
/// is saved during playback.
class ProgressRepository extends ChangeNotifier {
  final StorageService _storage;

  ProgressRepository(this._storage);

  PlaybackProgress? getProgress(String bookId) {
    final v = _storage.progress.get(bookId);
    if (v == null) return null;
    return PlaybackProgress.fromJson(Map<String, dynamic>.from(v as Map));
  }

  /// All saved progress records, most recently updated first.
  /// Data source for the history page.
  List<PlaybackProgress> getAll() {
    return _storage.progress.values
        .map((v) =>
            PlaybackProgress.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> saveProgress(PlaybackProgress progress) async {
    await _storage.progress.put(progress.bookId, progress.toJson());
    notifyListeners();
  }

  Future<void> clearProgress(String bookId) async {
    await _storage.progress.delete(bookId);
    notifyListeners();
  }
}
