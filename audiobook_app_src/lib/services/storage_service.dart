import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show Offset;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/bookshelf_book.dart';
import '../models/listen_session.dart';
import '../models/playback_progress.dart';

/// Manages Hive box initialization and provides access to local storage.
class StorageService {
  static const String bookshelfBox = 'bookshelf';
  static const String progressBox = 'playback_progress';
  static const String configBox = 'app_config';
  static const String listenSessionsBox = 'listen_sessions';
  static const String listeningStatsBox = 'listening_stats';

  /// 章节独立存储（PERF-01）：key = bookId，value = List<Map>（与旧内嵌结构一致）。
  /// 拆出来的目的是消除写放大——改一次封面不再重写上千条章节。
  static const String chaptersBox = 'chapters';

  static bool _hiveReady = false;

  /// 仅测试用：纯 Dart 测试里不便走 [init]（依赖 Flutter binding 与
  /// `Hive.initFlutter()`），由测试自行 `Hive.init` + `openBox` 后调用本方法放行。
  @visibleForTesting
  static void markReadyForTesting() => _hiveReady = true;

  /// 仅测试用：撤销 [markReadyForTesting] 的效果，避免污染同一进程内的其他测试。
  @visibleForTesting
  static void resetReadyForTesting() => _hiveReady = false;

  static Future<void> init() async {
    debugPrint('StorageService: starting init...');
    await Hive.initFlutter();
    debugPrint('StorageService: Hive.initFlutter done');

    // 书签功能已移除，清掉遗留的 box 文件，避免垃圾数据常驻
    try {
      await Hive.deleteBoxFromDisk('bookmarks');
    } catch (_) {}

    Hive.registerAdapter(PlaybackProgressAdapter());
    Hive.registerAdapter(BookshelfBookAdapter());
    Hive.registerAdapter(ListenSessionAdapter());
    debugPrint('StorageService: adapters registered');

    await Hive.openBox(bookshelfBox);
    await Hive.openBox(progressBox);
    await Hive.openBox(configBox);
    await Hive.openBox(listenSessionsBox);
    await Hive.openBox(listeningStatsBox);
    await Hive.openBox(chaptersBox);
    debugPrint('StorageService: all boxes opened');
    _hiveReady = true;
  }

  static bool get isStorageReady => _hiveReady;

  bool get isReady => _hiveReady;

  Box<dynamic> get bookshelf =>
      _hiveReady ? Hive.box(bookshelfBox) : _EmptyBox();
  Box<dynamic> get progress =>
      _hiveReady ? Hive.box(progressBox) : _EmptyBox();
  Box<dynamic> get config =>
      _hiveReady ? Hive.box(configBox) : _EmptyBox();
  Box<dynamic> get listenSessions =>
      _hiveReady ? Hive.box(listenSessionsBox) : _EmptyBox();
  Box<dynamic> get listeningStats =>
      _hiveReady ? Hive.box(listeningStatsBox) : _EmptyBox();

  /// 章节独立存储（PERF-01）。未就绪时返回 [_EmptyBox]，读为 null、写被忽略。
  Box<dynamic> get chapters =>
      _hiveReady ? Hive.box(chaptersBox) : _EmptyBox();

  // --- Cloud drive credentials ---

  Future<void> saveBaiduAppKey(String appKey) async {
    await config.put('baidu_app_key', appKey);
  }

  String? getBaiduAppKey() {
    final v = config.get('baidu_app_key');
    return v?.toString();
  }

  Future<void> saveBaiduToken(String token) async {
    await config.put('baidu_token', token);
  }

  String? getBaiduToken() {
    final v = config.get('baidu_token');
    return v?.toString();
  }

  Future<void> saveBaiduCookie(String cookie) async {
    await config.put('baidu_cookie', cookie);
  }

  String? getBaiduCookie() {
    final v = config.get('baidu_cookie');
    return v?.toString();
  }

  Future<void> saveQuarkCookie(String cookie) async {
    await config.put('quark_cookie', cookie);
  }

  String? getQuarkCookie() {
    final v = config.get('quark_cookie');
    return v?.toString();
  }

  // --- 播放设置（按书独立存储）---

  /// 跳过片头秒数（0 = 不跳过）。每本书单独配置，互不影响。
  Future<void> saveSkipIntroSeconds(String bookId, int seconds) async {
    await config.put('skip_intro_$bookId', seconds);
  }

  int getSkipIntroSeconds(String bookId) =>
      (config.get('skip_intro_$bookId') as num?)?.toInt() ?? 0;

  /// 跳过片尾秒数（0 = 不跳过）。每本书单独配置，互不影响。
  Future<void> saveSkipOutroSeconds(String bookId, int seconds) async {
    await config.put('skip_outro_$bookId', seconds);
  }

  int getSkipOutroSeconds(String bookId) =>
      (config.get('skip_outro_$bookId') as num?)?.toInt() ?? 0;

  // --- 全网搜书 / 书架偏好 ---

  /// 转存分享的目标目录。fid 为空表示用夸克默认的「来自：分享」目录。
  /// path 为该目录的绝对路径（如 /有声书），供书架长按跳转网盘时拼面包屑。
  Future<void> saveQuarkSaveDir(String fid, String name, String path) async {
    await config.put('quark_save_dir_fid', fid);
    await config.put('quark_save_dir_name', name);
    await config.put('quark_save_dir_path', path);
  }

  String? getQuarkSaveDirFid() {
    final v = config.get('quark_save_dir_fid')?.toString();
    return (v == null || v.isEmpty) ? null : v;
  }

  String? getQuarkSaveDirName() => config.get('quark_save_dir_name')?.toString();

  String? getQuarkSaveDirPath() => config.get('quark_save_dir_path')?.toString();

  /// 书架布局：每行列数。0 表示列表视图。
  Future<void> saveShelfColumns(int columns) async {
    await config.put('shelf_columns', columns);
  }

  int getShelfColumns() =>
      (config.get('shelf_columns') as num?)?.toInt() ?? 3;

  // --- 悬浮播放球位置 ---

  /// 浮球球心 X（占屏宽比例 0~1，兼容旋转/分辨率变化）。
  Future<void> saveBallDxRatio(double ratio) async {
    await config.put('ball_dx_ratio', ratio);
  }

  double getBallDxRatio() =>
      (config.get('ball_dx_ratio') as num?)?.toDouble() ?? double.nan;

  /// 浮球球心 Y（占屏高比例 0~1）。
  Future<void> saveBallDyRatio(double ratio) async {
    await config.put('ball_dy_ratio', ratio);
  }

  double getBallDyRatio() =>
      (config.get('ball_dy_ratio') as num?)?.toDouble() ?? 0.62;

  /// 是否开启了「减弱动效」（低端机降级）。
  Future<void> saveReduceMotion(bool value) async {
    await config.put('reduce_motion', value);
  }

  bool getReduceMotion() => config.get('reduce_motion') as bool? ?? false;

  /// 旧协议：贴边侧（true = 右）。无新坐标时用它推算初始 X。
  Future<void> saveBallRight(bool right) async {
    await config.put('ball_right', right);
  }

  bool getBallRight() => config.get('ball_right') as bool? ?? true;

  // --- 详情页目录工具条位置（绝对像素，null = 默认右下角）---

  Future<void> saveChapterToolbarOffset(Offset offset) async {
    await config.put('chapter_toolbar_dx', offset.dx);
    await config.put('chapter_toolbar_dy', offset.dy);
  }

  Offset? getChapterToolbarOffset() {
    final dx = (config.get('chapter_toolbar_dx') as num?)?.toDouble();
    final dy = (config.get('chapter_toolbar_dy') as num?)?.toDouble();
    if (dx == null || dy == null) return null;
    return Offset(dx, dy);
  }
}

/// A no-op box implementation used when Hive is not available.
class _EmptyBox implements Box<dynamic> {
  dynamic get key => null;

  @override
  String get name => '__empty__';

  @override
  bool get isOpen => false;

  @override
  bool get isEmpty => true;

  @override
  bool get isNotEmpty => false;

  @override
  int get length => 0;

  @override
  Iterable get keys => const [];

  @override
  Iterable<dynamic> get values => const [];

  @override
  Map<dynamic, dynamic> toMap() => {};

  @override
  bool containsKey(key) => false;

  @override
  dynamic get(key, {defaultValue}) => defaultValue;

  @override
  dynamic getAt(int index) => null;

  @override
  Future<void> put(key, value) async {}

  @override
  Future<void> putAt(int index, value) async {}

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async {}

  @override
  Future<int> add(value) async => 0;

  @override
  Future<Iterable<int>> addAll(Iterable values) async => const [];

  @override
  Future<void> delete(key) async {}

  @override
  Future<void> deleteAt(int index) async {}

  @override
  Future<void> deleteAll(Iterable keys) async {}

  @override
  Future<int> clear() async => 0;

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  Stream<BoxEvent> watch({key}) => const Stream.empty();

  @override
  Iterable<dynamic> valuesBetween({startKey, endKey}) => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
