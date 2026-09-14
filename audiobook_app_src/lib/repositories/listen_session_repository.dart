import 'package:flutter/foundation.dart';

import '../models/listen_session.dart';
import '../services/storage_service.dart';

/// 收听会话仓库：历史的真实数据源。
/// 每次手动点播 = 新建会话；自动连播/切章 = 更新当前会话。
class ListenSessionRepository extends ChangeNotifier {
  final StorageService _storage;

  static const String _prefix = 'session_';

  ListenSessionRepository(this._storage);

  List<ListenSession> getAll() {
    return _storage.listenSessions.values
        .map((v) =>
            ListenSession.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  /// 手动点播：新建一条会话。
  Future<ListenSession> create({
    required String bookId,
    required String bookTitle,
    required int chapterIndex,
    int positionSeconds = 0,
    int? chapterCount,
    String? chapterTitle,
  }) async {
    final session = ListenSession(
      id: '$_prefix${DateTime.now().microsecondsSinceEpoch}',
      bookId: bookId,
      bookTitle: bookTitle,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      chapterIndex: chapterIndex,
      positionSeconds: positionSeconds,
      chapterCount: chapterCount,
      chapterTitle: chapterTitle,
    );
    await _storage.listenSessions.put(session.id, session.toJson());
    notifyListeners();
    return session;
  }

  /// 更新会话进度（自动连播、定时保存时调用）。
  Future<void> updateProgress(ListenSession session,
      {required int chapterIndex,
      required int positionSeconds,
      String? chapterTitle}) async {
    final updated = session.copyWithProgress(
      chapterIndex: chapterIndex,
      positionSeconds: positionSeconds,
      chapterTitle: chapterTitle,
    );
    await _storage.listenSessions.put(updated.id, updated.toJson());
    notifyListeners();
  }

  Future<void> delete(String sessionId) async {
    await _storage.listenSessions.delete(sessionId);
    notifyListeners();
  }

  Future<void> clearAll() async {
    await _storage.listenSessions.clear();
    notifyListeners();
  }
}
