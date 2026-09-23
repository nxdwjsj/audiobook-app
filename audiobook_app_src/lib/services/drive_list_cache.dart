import 'dart:collection';

import '../models/drive_item.dart';

/// 网盘目录列举的内存缓存（PERF-03）。
///
/// 网盘列目录要走一次网络往返，而 UI 里存在大量「来回切换」的场景：
/// 面包屑回上级、进详情再返回、切网盘再切回来、把同一本多层级书反复加入书架。
/// 这些场景下同一目录往往在几秒内被列多次。
///
/// 设计取舍：
/// - **TTL 默认 60 秒**：网盘内容变化频率低，60 秒足够吃掉绝大多数重复请求，
///   又不至于让用户长时间看到过期列表；
/// - **LRU 上限 32 个目录**：内存占用可控（只存引用），目录特别多的深度浏览
///   也不会无限增长；
/// - **必须配套强制失效入口**：调用方在「下拉刷新 / 点刷新 / 失败重试」时必须
///   用 `forceRefresh`（对应 [invalidate]），否则用户会以为网盘没更新。
///
/// 返回的列表是**副本**，调用方随便改都不会污染缓存。
class DriveListCache {
  DriveListCache({
    this.ttl = const Duration(seconds: 60),
    this.maxEntries = 32,
  });

  /// 全局实例：跨页面复用才能拿到「二次进入同一目录」的收益；
  /// 新鲜度由 TTL + 强制刷新兜底。
  static final DriveListCache instance = DriveListCache();

  final Duration ttl;
  final int maxEntries;

  /// LinkedHashMap 尾部为最近使用（LRU）。
  final LinkedHashMap<String, _CacheEntry> _entries =
      LinkedHashMap<String, _CacheEntry>();

  /// 缓存键：同一路径在不同网盘 / 不同 fid 下是不同目录，必须区分。
  static String keyFor(DriveType type, String path, String? dirFileId) =>
      '${type.name}|${dirFileId ?? ''}|$path';

  /// 取缓存；未命中或已过期返回 null（过期条目顺手丢弃）。
  List<DriveItem>? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.storedAt) > ttl) return null;
    _entries[key] = entry; // LRU touch
    return List<DriveItem>.of(entry.items);
  }

  /// 写入缓存，并淘汰最久未使用的条目。
  void put(String key, List<DriveItem> items) {
    _entries.remove(key);
    _entries[key] = _CacheEntry(items, DateTime.now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 让某个目录失效（下拉刷新 / 刷新按钮 / 失败重试时调用）。
  void invalidate(String key) => _entries.remove(key);

  /// 清空全部缓存（如切换账号后）。
  void clear() => _entries.clear();

  /// 当前缓存条目数（测试用）。
  int get length => _entries.length;
}

class _CacheEntry {
  final List<DriveItem> items;
  final DateTime storedAt;

  _CacheEntry(this.items, this.storedAt);
}
