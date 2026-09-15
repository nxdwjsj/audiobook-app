import 'package:flutter/foundation.dart';

import '../models/listen_session.dart';
import '../services/storage_service.dart';

/// 收听会话仓库：历史的真实数据源。
/// 每次手动点播 = 新建会话；自动连播/切章 = 更新当前会话。
/// 每本书最多保留 1 条记录（最新的），总数上限 100 条。
class ListenSessionRepository extends ChangeNotifier {
  final StorageService _storage;

  static const String _prefix = 'session_';
  static const int _maxRecords = 100;

  ListenSessionRepository(this._storage);

  List<ListenSession> getAll() {
    final list = _storage.listenSessions.values
        .map((v) =>
            ListenSession.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list.take(_maxRecords).toList();
  }

  /// 手动点播：新建一条会话，删除同本书的旧记录（每本书只保留最新）。
  Future<ListenSession> create({
    required String bookId,
    required String bookTitle,
    required int chapterIndex,
    int positionSeconds = 0,
    int? chapterCount,
    String? chapterTitle,
  }) async {
    // 删除同一本书的所有旧 session（通过索引遍历 value+key）
    for (var i = _storage.listenSessions.length - 1; i >= 0; i--) {
      try {
        final json = _storage.listenSessions.getAt(i) as Map<String, dynamic>;
        if (json['bookId'] == bookId) {
          await _storage.listenSessions.deleteAt(i);
        }
      } catch (_) {}
    }

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
    await _trimToLimit();
    notifyListeners();
    return session;
  }

  /// 总量超过 [_maxRecords] 时删除最旧的记录。
  Future<void> _trimToLimit() async {
    while (_storage.listenSessions.length > _maxRecords) {
      // 找 startedAt 最早的一条删掉
      String? oldestId;
      DateTime? oldestAt;
      for (final entry in _storage.listenSessions.toMap().entries) {
        final json = entry.value as Map;
        final at = DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.now();
        if (oldestAt == null || at.isBefore(oldestAt)) {
          oldestAt = at;
          oldestId = entry.key as String;
        }
      }
      if (oldestId == null) break;
      await _storage.listenSessions.delete(oldestId);
    }
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
