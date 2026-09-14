import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// 单本书的累计收听时长。
class BookListenStat {
  final String bookId;
  final String title;
  final int seconds;

  const BookListenStat({
    required this.bookId,
    required this.title,
    required this.seconds,
  });
}

/// 收听时长统计：按天累计（供热力图）+ 按书累计（供排行）。
/// 数据以纯 Map 存在 Hive box `listening_stats` 中，不占用 typeId。
class StatsRepository extends ChangeNotifier {
  static const String _dailyKey = 'daily';
  static const String _booksKey = 'books';

  final StorageService _storage;

  Map<String, int> _dailySeconds = {};
  Map<String, Map<String, dynamic>> _books = {};
  bool _dirty = false;

  StatsRepository(this._storage) {
    _load();
  }

  void _load() {
    try {
      final daily = _storage.listeningStats.get(_dailyKey);
      if (daily is Map) {
        _dailySeconds = daily.map(
          (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
        );
      }
      final books = _storage.listeningStats.get(_booksKey);
      if (books is Map) {
        _books = books.map(
          (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
        );
      }
    } catch (e) {
      debugPrint('[Stats] 读取统计失败: $e');
    }
  }

  /// 日期键：yyyy-MM-dd（本地时区）。
  static String dayKey(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// 某天累计收听秒数。
  int secondsOn(DateTime day) => _dailySeconds[dayKey(day)] ?? 0;

  /// 全部累计收听秒数。
  int get totalSeconds =>
      _dailySeconds.values.fold(0, (sum, v) => sum + v);

  /// 有收听记录的天数。
  int get listenedDays => _dailySeconds.values.where((v) => v > 0).length;

  /// 各书累计时长，按时长倒序。
  List<BookListenStat> get bookStats {
    final list = _books.entries
        .map((e) => BookListenStat(
              bookId: e.key,
              title: (e.value['title'] as String?) ?? '未知书籍',
              seconds: (e.value['seconds'] as num?)?.toInt() ?? 0,
            ))
        .toList()
      ..sort((a, b) => b.seconds.compareTo(a.seconds));
    return list;
  }

  /// 累加一段收听时长（由播放器在真正播放时调用）。
  void addSeconds(int seconds, {String? bookId, String? bookTitle}) {
    if (seconds <= 0) return;
    final key = dayKey(DateTime.now());
    _dailySeconds[key] = (_dailySeconds[key] ?? 0) + seconds;

    if (bookId != null && bookId.isNotEmpty) {
      final prev = _books[bookId];
      final prevSeconds = (prev?['seconds'] as num?)?.toInt() ?? 0;
      _books[bookId] = {
        'title': bookTitle ?? prev?['title'] ?? '未知书籍',
        'seconds': prevSeconds + seconds,
      };
    }

    _dirty = true;
    notifyListeners();
  }

  /// 落盘（播放器定时调用，避免频繁写 Hive）。
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await _storage.listeningStats.put(_dailyKey, _dailySeconds);
      await _storage.listeningStats.put(_booksKey, _books);
    } catch (e) {
      _dirty = true;
      debugPrint('[Stats] 保存统计失败: $e');
    }
  }
}