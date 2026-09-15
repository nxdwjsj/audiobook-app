import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';
import '../services/book_source/book_source.dart';
import '../services/book_source/builtin_sources.dart';

/// 书源仓储：内置源（随 App 发布）+ 自定义源（Hive 持久化）。
///
/// 合并规则：
/// - 内置源总是存在（不可删除）；Hive 中存在同 id 记录时按存储内容分派：
///   - enabled=false → 该内置源被用户关闭
///   - 其它 → 同 id 自定义规则（覆盖内置版，可用于热修复站点改版）
/// - 自定义源（非内置 id）从 Hive 读规则本体
///
/// ChangeNotifier：管理页 / 搜书页监听增删改与开关变化。
class BookSourceRepository extends ChangeNotifier {
  BookSourceRepository(this._storage);

  final StorageService _storage;

  static const String _customKey = 'custom_book_sources';
  static const String _disabledKey = 'disabled_book_sources';

  List<BookSource> _custom = [];
  Set<String> _disabled = {};

  // ------------------------------------------------------------------
  // 读取
  // ------------------------------------------------------------------

  /// 全部书源（内置在前、自定义在后），按名称排序更符合管理页直觉。
  List<BookSource> get all {
    final list = [...kBuiltinBookSources, ..._custom];
    list.sort((a, b) {
      final ba = _builtinOrder(a), bb = _builtinOrder(b);
      if (ba != bb) return ba - bb;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  int _builtinOrder(BookSource s) =>
      kBuiltinSourceIds.contains(s.id) ? 0 : 1;

  /// 当前启用、参与全网搜书的书源。
  List<BookSource> get enabled =>
      all.where((s) => !_disabled.contains(s.id)).toList();

  bool isBuiltin(BookSource s) => kBuiltinSourceIds.contains(s.id);

  bool isEnabled(BookSource s) => !_disabled.contains(s.id);

  // ------------------------------------------------------------------
  // 持久化
  // ------------------------------------------------------------------

  /// 启动时从 Hive 恢复自定义源与禁用列表。
  Future<void> load() async {
    try {
      final raw = _storage.config.get(_customKey);
      if (raw is List) {
        _custom = raw
            .map((v) {
              try {
                return BookSource.fromJson(
                    Map<String, dynamic>.from(v as Map));
              } catch (e) {
                debugPrint('[BookSource] 跳过损坏的自定义源: $e');
                return null;
              }
            })
            .whereType<BookSource>()
            .toList();
      }
      final dis = _storage.config.get(_disabledKey);
      if (dis is List) {
        _disabled = dis.map((e) => e.toString()).toSet();
      }
    } catch (e) {
      debugPrint('[BookSource] load 失败: $e');
    }
  }

  Future<void> _saveCustom() async {
    await _storage.config.put(
        _customKey, _custom.map((s) => s.toJson()).toList());
  }

  Future<void> _saveDisabled() async {
    await _storage.config.put(_disabledKey, _disabled.toList());
  }

  // ------------------------------------------------------------------
  // 增删改 / 开关
  // ------------------------------------------------------------------

  Future<void> setEnabled(BookSource s, bool value) async {
    if (value) {
      _disabled.remove(s.id);
    } else {
      _disabled.add(s.id);
    }
    await _saveDisabled();
    notifyListeners();
  }

  /// 新增或覆盖（同 id）。内置源 id 也可写入 = 覆盖内置规则。
  Future<void> upsert(BookSource s) async {
    final i = _custom.indexWhere((c) => c.id == s.id);
    if (i >= 0) {
      _custom[i] = s;
    } else {
      _custom.add(s);
    }
    await _saveCustom();
    notifyListeners();
  }

  /// 删除自定义源。内置源不可删（返回 false）。
  Future<bool> remove(String id) async {
    if (kBuiltinSourceIds.contains(id)) return false;
    final before = _custom.length;
    _custom.removeWhere((c) => c.id == id);
    if (_custom.length == before) return false;
    _disabled.remove(id);
    await _saveCustom();
    await _saveDisabled();
    notifyListeners();
    return true;
  }

  /// 恢复某个内置源为 App 出厂规则（删除覆盖 + 启用）。
  Future<void> resetBuiltin(String id) async {
    if (!kBuiltinSourceIds.contains(id)) return;
    _custom.removeWhere((c) => c.id == id);
    _disabled.remove(id);
    await _saveCustom();
    await _saveDisabled();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // 导入导出
  // ------------------------------------------------------------------

  /// 导出一个源为 JSON 文本（分享给别人用）。
  String exportSource(BookSource s) => s.toPrettyJson();

  /// 解析书源 JSON。支持单个对象或数组，返回解析成功的源列表。
  /// 格式错误抛 [FormatException]。
  Future<(List<BookSource> added, List<String> errors)> importFromText(
      String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('内容为空');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (e) {
      throw FormatException('不是合法的 JSON：$e');
    }

    final list = decoded is List ? decoded : [decoded];
    final added = <BookSource>[];
    final errors = <String>[];
    for (final item in list) {
      if (item is! Map) {
        errors.add('跳过非对象条目');
        continue;
      }
      try {
        final s = BookSource.fromJson(Map<String, dynamic>.from(item));
        await upsert(s);
        added.add(s);
      } on FormatException catch (e) {
        errors.add(e.message);
      }
    }
    return (added, errors);
  }
}
