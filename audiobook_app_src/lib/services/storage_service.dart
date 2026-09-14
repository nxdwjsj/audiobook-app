import 'package:flutter/foundation.dart';
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

  static bool _hiveReady = false;

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
    debugPrint('StorageService: all boxes opened');
    _hiveReady = true;
  }

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
