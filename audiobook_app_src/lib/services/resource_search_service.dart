import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/drive_item.dart';
import 'quark_drive_service.dart';

/// 一个待解析的夸克分享。
class ResourceHit {
  final String pwdId;
  final String? passcode;
  final String source;

  ResourceHit(this.pwdId, {this.passcode, this.source = 'manual'});

  String get url => 'https://pan.quark.cn/s/$pwdId';
}

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

/// 全网搜书：多渠道发现夸克分享 → 递归解析 → 按关键词打分排序。
///
/// 渠道与 tool/quark_crawler.dart 保持一致：
/// B 站搜索接口 / yigushi / yangzhiyi / slowread / fangkong。
class ResourceSearchService {
  ResourceSearchService(this._quark);

  final QuarkDriveService _quark;

  static const String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      'User-Agent': _browserUa,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    },
    validateStatus: (s) => s != null && s < 600,
  ));

  String? _biliCookieCache;

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
      final c = _channelRank(a.$2.source).compareTo(_channelRank(b.$2.source));
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
  // 发现渠道
  // ------------------------------------------------------------------

  /// 渠道优先级：0 = 策展类（提取码通常准确），1 = 其它（如 B 站，码多为推测）。
  static int _channelRank(String source) {
    switch (source) {
      case 'fangkong':
      case 'yigushi':
      case 'slowread':
      case 'yangzhiyi':
      case 'page':
        return 0;
      default:
        return 1;
    }
  }

  Future<List<ResourceHit>> _discover(
    String keyword,
    void Function(String)? onProgress,
  ) async {
    final found = <String, ResourceHit>{};
    void addAll(List<ResourceHit> list) {
      for (final l in list) {
        final exist = found[l.pwdId];
        if (exist == null) {
          found[l.pwdId] = l;
        } else if (_channelRank(l.source) < _channelRank(exist.source)) {
          // 同一个分享被多个渠道发现时，保留优先级更高渠道的提取码
          // （B 站的码常是从页面上下文猜的，容易 41007）
          found[l.pwdId] = l;
        }
      }
    }

    // 5 个渠道并行发现；单渠道超时/被封禁不影响其它渠道。
    onProgress?.call('发现中：B站 / 第一故事 / 故事网 / 合集 / 放空（并行）');
    final channels = <String, Future<List<ResourceHit>>>{
      'bilibili': _bilibili(keyword),
      'yigushi': _yigushi(keyword),
      'yangzhiyi': _yangzhiyi(keyword),
      'slowread': _slowread(keyword),
      'fangkong': _fangkong(keyword),
    };
    await Future.wait(channels.entries.map((e) async {
      try {
        addAll(await e.value);
      } catch (err) {
        debugPrint('[ResourceSearch] ${e.key}: $err');
      }
    }));

    return found.values.toList();
  }

  Future<List<ResourceHit>> _bilibili(String keyword) async {
    final out = <ResourceHit>[];
    for (final q in {'$keyword 夸克', keyword}) {
      try {
        final enc = Uri.encodeComponent(q);
        final url = 'https://api.bilibili.com/x/web-interface/search/type'
            '?search_type=video&keyword=$enc&page=1&page_size=20';
        final body = await _biliGet(url);
        final data = jsonDecode(body);
        if (data is Map && data['code'] == 0) {
          final results = (data['data']?['result'] as List<dynamic>? ?? []);
          final sb = StringBuffer();
          for (final r in results) {
            if (r is! Map) continue;
            sb
              ..writeln(r['title'] ?? '')
              ..writeln(r['description'] ?? '')
              ..writeln(r['tag'] ?? '');
          }
          out.addAll(_extract(sb.toString(), 'bilibili'));
        }
      } catch (e) {
        debugPrint('[ResourceSearch] bilibili「$q」: $e');
      }
      await _sleep(150);
    }
    return out;
  }

  Future<String> _biliGet(String url) async {
    var cookie = await _biliCookie();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _text(url, headers: {
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          if (cookie != null) 'Cookie': cookie,
        });
      } catch (e) {
        if (!e.toString().contains('412') || attempt == 2) rethrow;
        _biliCookieCache = null;
        await _sleep(600);
        cookie = await _biliCookie();
      }
    }
    throw StateError('unreachable');
  }

  Future<String?> _biliCookie() async {
    if (_biliCookieCache != null) return _biliCookieCache;
    try {
      final resp = await _dio.get<String>(
        'https://www.bilibili.com/',
        options: Options(responseType: ResponseType.plain),
      );
      final parts = <String>[];
      for (final c in resp.headers['set-cookie'] ?? const <String>[]) {
        final first = c.split(';').first.trim();
        if (first.startsWith('buvid3=') ||
            first.startsWith('buvid4=') ||
            first.startsWith('b_nut=')) {
          parts.add(first);
        }
      }
      if (parts.isNotEmpty) {
        _biliCookieCache = parts.join('; ');
        return _biliCookieCache;
      }
    } catch (_) {}
    final rnd = Random();
    String hex(int n) => List.generate(
        n, (_) => rnd.nextInt(16).toRadixString(16).toUpperCase()).join();
    _biliCookieCache = 'buvid3=${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-'
        '${hex(12)}infoc; b_nut=${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return _biliCookieCache;
  }

  Future<List<ResourceHit>> _yigushi(String keyword) async {
    final out = <ResourceHit>[];
    final seen = <String>{};
    final tokens =
        keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).take(3).toList();
    final queries = {...tokens, if (tokens.length > 1) keyword};
    for (final q in queries) {
      for (final mod in const ['youshengxiaoshuo', 'soft', 'xiqu', 'baby']) {
        String html;
        try {
          html = await _text(
              'https://www.yigushi.com/$mod/search.php?kw=${Uri.encodeComponent(q)}');
        } catch (e) {
          // 单个板块请求失败不该让整个渠道归零
          debugPrint('[ResourceSearch] yigushi/$mod: $e');
          continue;
        }
        final re = RegExp(
            r'<a href="(https://www\.yigushi\.com/[^"]+\.html)"[^>]*?target="_blank"[^>]*?title="([^"]+)"');
        final articles = <String>[];
        for (final m in re.allMatches(html)) {
          final title = m.group(2)!;
          if (!tokens.any((t) => title.contains(t))) continue;
          if (!seen.add(m.group(1)!)) continue;
          articles.add(m.group(1)!);
          if (articles.length >= 3) break;
        }
        for (final url in articles) {
          try {
            out.addAll(_extract(await _text(url), 'yigushi'));
          } catch (_) {}
          await _sleep(120);
        }
        await _sleep(120);
      }
    }
    return out;
  }

  Future<List<ResourceHit>> _yangzhiyi(String keyword) async {
    final out = <ResourceHit>[];
    final tokens =
        keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).take(2).toList();
    for (final q in tokens) {
      final resp = await _dio.post<String>(
        'https://mp3.yangzhiyi.com/zb_system/cmd.php?act=search',
        data: {'q': q},
        options: Options(
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      if ((resp.statusCode ?? 0) >= 400) continue;
      final re = RegExp(
          r'<h2[^>]*>\s*<a href="(https://mp3\.yangzhiyi\.com/[^"]+\.html)"[^>]*title="([^"]+)"');
      final articles = <String>[];
      for (final m in re.allMatches(resp.data ?? '')) {
        final title = m.group(2)!;
        if (!tokens.any((t) => title.contains(t))) continue;
        articles.add(m.group(1)!);
        if (articles.length >= 3) break;
      }
      for (final url in articles) {
        try {
          out.addAll(_extract(await _text(url), 'yangzhiyi'));
        } catch (_) {}
        await _sleep(120);
      }
      await _sleep(120);
    }
    return out;
  }

  Future<List<ResourceHit>> _slowread(String keyword) async {
    final tokens =
        keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final html = await _text('https://slowread.net/k/audiobook.html');
    final re = RegExp(
        r"<span>([^<]+)</span>\s*<a href='(https://pan\.quark\.cn/s/[0-9a-zA-Z_-]+)'");
    final out = <ResourceHit>[];
    for (final m in re.allMatches(html)) {
      final title = m.group(1)!;
      if (!tokens.any((t) => title.contains(t))) continue;
      out.add(ResourceHit(m.group(2)!.split('/').last, source: 'slowread'));
      if (out.length >= 5) break;
    }
    return out;
  }

  Future<List<ResourceHit>> _fangkong(String keyword) async {
    final html = await _text(
        'https://fangkong.cc/s/${Uri.encodeComponent(keyword)}.html');
    return _extract(html, 'fangkong');
  }

  // ------------------------------------------------------------------
  // 工具
  // ------------------------------------------------------------------

  List<ResourceHit> _extract(String html, String source) {
    final out = <ResourceHit>[];
    final seen = <String>{};
    final re = RegExp(r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)');
    for (final m in re.allMatches(html)) {
      final pwdId = m.group(1)!;
      if (!seen.add(pwdId)) continue;
      final start = max(0, m.start - 200);
      final end = min(html.length, m.end + 200);
      final window = html.substring(start, end);
      final pwdMatch = RegExp(
        r'(?:提取码|密码|pwd|passcode)\s*[:：]?\s*([0-9a-zA-Z]{4})\b',
        caseSensitive: false,
      ).firstMatch(window);
      out.add(ResourceHit(pwdId,
          passcode: pwdMatch?.group(1), source: source));
    }
    return out;
  }

  Future<String> _text(String url, {Map<String, String>? headers}) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain, headers: headers),
    );
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return resp.data ?? '';
  }

  Future<void> _sleep(int ms) =>
      Future.delayed(Duration(milliseconds: ms + Random().nextInt(150)));
}
