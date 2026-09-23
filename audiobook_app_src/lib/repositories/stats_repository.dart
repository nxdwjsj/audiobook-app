import 'dart:async';

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

  /// 通知节流窗口的默认值（PERF-02）。见 [notifyThrottle]。
  static const Duration defaultNotifyThrottle = Duration(seconds: 30);

  /// 通知节流窗口。
  ///
  /// 播放期间播放器每累计约 10 秒就会 `addSeconds` 一次，而统计页/书架页
  /// 都 `context.watch` 本仓储 —— 原先每次记账都 `notifyListeners()`，
  /// 5 分钟播放会造成约 30 次整页重建。这里把 addSeconds 与 flush 的通知
  /// 合并，保证任意这么长的窗口内最多通知一次（重建次数下降约 2/3）。
  final Duration notifyThrottle;

  final StorageService _storage;

  Map<String, int> _dailySeconds = {};
  Map<String, Map<String, dynamic>> _books = {};
  bool _dirty = false;

  /// 节流的尾部通知定时器（保证最终状态一定会刷出去）。
  Timer? _notifyTimer;

  /// 上次通知时间；null 表示还没通知过。
  DateTime? _lastNotifyAt;

  StatsRepository(
    this._storage, {
    this.notifyThrottle = defaultNotifyThrottle,
  }) {
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
    // 不再直接 notifyListeners()：改走节流，避免播放期间整页高频重建
    _notifyThrottled();
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
      return;
    }
    // 落盘成功后统一通知（同样受节流约束）
    _notifyThrottled();
  }

  /// 统一通知入口（节流）：
  /// 距上次通知已满 [notifyThrottle] → 立即通知；否则安排一次尾部通知，
  /// 确保最后一个数据点最终一定会反映到 UI 上。
  void _notifyThrottled() {
    final now = DateTime.now();
    final last = _lastNotifyAt;
    if (last == null || now.difference(last) >= notifyThrottle) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotifyAt = now;
      notifyListeners();
      return;
    }
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(notifyThrottle - now.difference(last), () {
      _notifyTimer = null;
      _lastNotifyAt = DateTime.now();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    // 尾部定时器必须在 dispose 前取消：否则会在仓储销毁后触发
    // notifyListeners()，抛 "A ChangeNotifier was used after being disposed"。
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}