import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/drive_item.dart';
import '../repositories/book_source_repository.dart';
import 'book_source/book_source_engine.dart';
import 'book_source/online_book_hit.dart';
import 'book_source/resource_hit.dart';
import 'quark_drive_service.dart';

export 'book_source/resource_hit.dart';

/// 一个分享的解析结果（全网搜书的列表项）。
class ResourceResult {
  final String title;
  final String shareUrl;
  final String? passcode;
  final String source;
  final List<DriveItem> items;
  final int keywordHits;
  final String? error;

  /// 这本书在分享里的顶层条目。转存时只提交这些，
  /// 避免「点一本书却把整个合集搬进网盘」。
  final List<Map<String, dynamic>>? shareEntries;

  ResourceResult({
    required this.title,
    required this.shareUrl,
    required this.source,
    required this.items,
    this.passcode,
    this.keywordHits = 0,
    this.error,
    this.shareEntries,
  });

  List<DriveItem> get audioItems => items.where((i) => i.isAudio).toList();

  int get audioBytes => audioItems.fold(0, (s, i) => s + i.size);
}

/// 全网搜书：启用书源发现夸克分享 → 递归解析 → 按关键词打分排序。
///
/// 书源由 BookSourceRepository 提供（内置 5 源 + 用户自定义/导入），
/// 每个源由 BookSourceEngine 按规则执行；解析/打分逻辑与渠道无关。
class ResourceSearchService {
  ResourceSearchService(this._quark, this._sources);

  final QuarkDriveService _quark;
  final BookSourceRepository _sources;

  /// 一个分享里最多展示几本（合集分享可能塞几十本，避免刷屏）
  static const int _maxGroupsPerShare = 20;

  /// 搜索入口。[onProgress] 回传阶段进度；[onResult] 在每解析完一个分享时立即
  /// 回调，用于边解析边出结果（不必等全部解析完）。多个分享并发解析。
  Future<List<ResourceResult>> search(
    String keyword, {
    int maxParse = 8,
    int concurrency = 3,
    void Function(String message)? onProgress,
    void Function(ResourceResult result)? onResult,
  }) async {
    onProgress?.call('正在发现分享链接…');
    final hits = await _discover(keyword, onProgress);
    if (hits.isEmpty) return [];

    // 策展类渠道优先，避免 B 站噪声挤占解析名额
    final indexed = [for (var i = 0; i < hits.length; i++) (i, hits[i])];
    indexed.sort((a, b) {
      // 使用书源的 rank 排序（0=策展类，1=其它）
      final aSource = _sources.all.where((s) => s.id == a.$2.source).firstOrNull;
      final bSource = _sources.all.where((s) => s.id == b.$2.source).firstOrNull;
      final aRank = aSource?.rank ?? 1;
      final bRank = bSource?.rank ?? 1;
      final c = aRank.compareTo(bRank);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    var targets = [for (final e in indexed) e.$2];
    if (targets.length > maxParse) targets = targets.sublist(0, maxParse);

    final tokens =
        keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final results = <ResourceResult>[];
    final queue = [...targets];
    var started = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final hit = queue.removeAt(0);
        started++;
        onProgress?.call('解析 $started/${targets.length}：${hit.pwdId}');
        // 一个分享可能含多本书 → 拆成多条结果逐条抛出，边解析边显示
        final list = await _parseMany(hit, tokens);
        for (final r in list) {
          results.add(r);
          onResult?.call(r);
        }
      }
    }

    await Future.wait(
        List.generate(min(concurrency, targets.length), (_) => worker()));

    results.sort((a, b) {
      // 成功的排前面；再按关键词命中、音频数
      if ((a.error == null) != (b.error == null)) {
        return a.error == null ? -1 : 1;
      }
      final c = b.keywordHits.compareTo(a.keywordHits);
      if (c != 0) return c;
      return b.audioItems.length.compareTo(a.audioItems.length);
    });
    return results;
  }

  /// 解析一个分享，**按书拆分**返回多条结果（合集分享会出多本）。
  Future<List<ResourceResult>> _parseMany(
    ResourceHit hit,
    List<String> tokens,
  ) async {
    try {
      final groups = await _parseGroupsWithFallback(hit);
      final out = <ResourceResult>[];
      for (final g in groups) {
        if (g.audioItems.isEmpty) continue;
        out.add(ResourceResult(
          title: g.title,
          shareUrl: hit.url,
          passcode: hit.passcode,
          source: hit.source,
          items: g.audioItems,
          keywordHits: _score(g.title, g.audioItems, tokens),
          shareEntries: g.entries,
        ));
      }
      if (out.isEmpty) {
        return [
          ResourceResult(
            title: '没有音频',
            shareUrl: hit.url,
            passcode: hit.passcode,
            source: hit.source,
            items: const [],
            error: '该分享里没有可直接播放的音频',
          ),
        ];
      }
      // 一个合集塞了几十本时，只留下命中最好的前几本，避免刷屏
      if (out.length > _maxGroupsPerShare) {
        out.sort((a, b) {
          final c = b.keywordHits.compareTo(a.keywordHits);
          return c != 0 ? c : b.audioItems.length.compareTo(a.audioItems.length);
        });
        return out.sublist(0, _maxGroupsPerShare);
      }
      return out;
    } catch (e) {
      return [
        ResourceResult(
          title: '解析失败',
          shareUrl: hit.url,
          passcode: hit.passcode,
          source: hit.source,
          items: const [],
          error: e.toString(),
        ),
      ];
    }
  }

  /// 提取码是从页面上下文猜的，可能张冠李戴（41007）→ 退回无提取码重试。
  Future<List<ShareGroup>> _parseGroupsWithFallback(ResourceHit hit) async {
    try {
      final (groups, _) =
          await _quark.parseShareGroups(hit.url, pwd: hit.passcode);
      return groups;
    } catch (e) {
      if (hit.passcode != null &&
          hit.passcode!.isNotEmpty &&
          e.toString().contains('41007')) {
        final (groups, _) = await _quark.parseShareGroups(hit.url);
        return groups;
      }
      rethrow;
    }
  }

  int _score(String title, List<DriveItem> items, List<String> tokens) {
    if (tokens.isEmpty) return 0;
    var hits = 0;
    for (final t in tokens) {
      if (title.contains(t)) hits += 5;
    }
    var fileHits = 0;
    for (final f in items) {
      if (tokens.any((t) => f.name.contains(t))) {
        fileHits++;
        if (fileHits >= 10) break;
      }
    }
    return hits + fileHits;
  }

  // ------------------------------------------------------------------
  // 发现渠道（书源规则驱动）
  // ------------------------------------------------------------------

  Future<List<ResourceHit>> _discover(
    String keyword,
    void Function(String)? onProgress,
  ) async {
    final found = <String, ResourceHit>{};

    /// 书源 rank（0=策展类，1=其它）。rank 未知按 1 处理。
    int rankOf(String id) {
      final s = _sources.all.where((s) => s.id == id).firstOrNull;
      return s?.rank ?? 1;
    }

    void addAll(List<ResourceHit> list) {
      for (final l in list) {
        final exist = found[l.pwdId];
        if (exist == null) {
          found[l.pwdId] = l;
        } else if (rankOf(l.source) < rankOf(exist.source)) {
          // 同一个分享被多个渠道发现时，保留优先级更高渠道的提取码
          // （B 站的码常是从页面上下文猜的，容易 41007）
          found[l.pwdId] = l;
        }
      }
    }

    final sources = _sources.enabled;
    if (sources.isEmpty) {
      onProgress?.call('没有启用的书源，去书源管理页开启或导入');
      return [];
    }
    // online 型源不产夸克分享，由搜索页单独调 searchOnline，这里跳过
    final quarkSources = sources.where((s) => !s.isOnline).toList();
    if (quarkSources.isEmpty) {
      onProgress?.call('没有启用中的夸克网盘类书源');
      return [];
    }
    // 各书源并行发现；单源超时/被封禁不影响其它源。
    onProgress?.call(
        '发现中：${quarkSources.map((s) => s.name).join(' / ')}（并行）');
    final engines = {
      for (final s in quarkSources) s.id: BookSourceEngine(s),
    };
    await Future.wait(engines.entries.map((e) async {
      try {
        addAll((await e.value.run(keyword)) ?? const []);
      } catch (err) {
        debugPrint('[ResourceSearch] ${e.key}: $err');
      }
    }));

    return found.values.toList();
  }

  // ------------------------------------------------------------------
  // online 型书源（在线听书站）
  // ------------------------------------------------------------------

  /// 搜索所有启用的 online 型源，返回可直接在线收听的书。
  Future<List<OnlineBookHit>> searchOnline(
    String keyword, {
    void Function(String message)? onProgress,
  }) async {
    final sources = _sources.enabled.where((s) => s.isOnline).toList();
    if (sources.isEmpty) return [];
    onProgress?.call(
        '在线书源搜索：${sources.map((s) => s.name).join(' / ')}');
    final out = <OnlineBookHit>[];
    await Future.wait(sources.map((s) async {
      try {
        final hits = await BookSourceEngine(s).searchOnline(keyword);
        if (hits.isNotEmpty) out.addAll(hits);
      } catch (err) {
        debugPrint('[ResourceSearch] online ${s.id}: $err');
      }
    }));
    // 按书名排序，同名去重（不同源搜到同一本时保留第一个）
    final seen = <String>{};
    out.retainWhere((h) => seen.add(h.detailUrl));
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  /// 解析一本在线书的章节列表（供加入书架时调用）。
  Future<OnlineBookDetail> resolveOnlineChapters(OnlineBookHit hit) async {
    final s = _sources.all.where((x) => x.id == hit.source).firstOrNull;
    if (s == null) {
      throw StateError('书源 ${hit.source} 不存在（可能已被删除）');
    }
    return BookSourceEngine(s).fetchOnlineChapters(hit.detailUrl);
  }

  /// 播放时懒解析：在线书的一个章节地址 → 音频直链。
  /// 章节地址已是直链时原样返回（引擎内部判断）。
  Future<String> resolveOnlineAudio(String sourceId, String chapterUrl) async {
    final s = _sources.all.where((x) => x.id == sourceId).firstOrNull;
    if (s == null) {
      throw StateError('书源 $sourceId 不存在（可能已被删除）');
    }
    return BookSourceEngine(s).fetchOnlineAudio(chapterUrl);
  }
}
