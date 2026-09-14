import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/drive_item.dart';
import 'cloud_drive_service.dart';
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

  ResourceResult({
    required this.title,
    required this.shareUrl,
    required this.source,
    required this.items,
    this.passcode,
    this.keywordHits = 0,
    this.error,
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

  /// 搜索入口。[onProgress] 用于把阶段进度回传给 UI。
  Future<List<ResourceResult>> search(
    String keyword, {
    int maxParse = 8,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在发现分享链接…');
    final hits = await _discover(keyword, onProgress);
    if (hits.isEmpty) return [];

    // 策展类渠道优先，避免 B 站噪声挤占解析名额
    const priority = {
      'fangkong': 0,
      'yigushi': 0,
      'slowread': 0,
      'yangzhiyi': 0,
    };
    final indexed = [for (var i = 0; i < hits.length; i++) (i, hits[i])];
    indexed.sort((a, b) {
      final c = (priority[a.$2.source] ?? 1).compareTo(priority[b.$2.source] ?? 1);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    var targets = [for (final e in indexed) e.$2];
    if (targets.length > maxParse) targets = targets.sublist(0, maxParse);

    final tokens =
        keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final results = <ResourceResult>[];
    for (var i = 0; i < targets.length; i++) {
      final hit = targets[i];
      onProgress?.call('解析 ${i + 1}/${targets.length}：${hit.pwdId}');
      results.add(await _parseOne(hit, tokens));
      await _sleep(300);
    }

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

  Future<ResourceResult> _parseOne(ResourceHit hit, List<String> tokens) async {
    try {
      var parsed = await _parseWithFallback(hit);
      final title = parsed.folderName ?? '分享资源';
      final hits = _score(title, parsed.items, tokens);
      return ResourceResult(
        title: title,
        shareUrl: hit.url,
        passcode: hit.passcode,
        source: hit.source,
        items: parsed.items,
        keywordHits: hits,
      );
    } catch (e) {
      return ResourceResult(
        title: '解析失败',
        shareUrl: hit.url,
        passcode: hit.passcode,
        source: hit.source,
        items: const [],
        error: e.toString(),
      );
    }
  }

  /// 提取码是从页面上下文猜的，可能张冠李戴（41007）→ 退回无提取码重试。
  Future<ShareParseResult> _parseWithFallback(ResourceHit hit) async {
    try {
      return await _quark.parseShareLinkRecursive(
        hit.url,
        pwd: hit.passcode,
      );
    } catch (e) {
      if (hit.passcode != null &&
          hit.passcode!.isNotEmpty &&
          e.toString().contains('41007')) {
        return await _quark.parseShareLinkRecursive(hit.url);
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

  Future<List<ResourceHit>> _discover(
    String keyword,
    void Function(String)? onProgress,
  ) async {
    final found = <String, ResourceHit>{};
    void addAll(List<ResourceHit> list) {
      for (final l in list) {
        found.putIfAbsent(l.pwdId, () => l);
      }
    }

    onProgress?.call('渠道：B 站搜索');
    try {
      addAll(await _bilibili(keyword));
    } catch (e) {
      debugPrint('[ResourceSearch] bilibili: $e');
    }

    onProgress?.call('渠道：第一故事');
    try {
      addAll(await _yigushi(keyword));
    } catch (e) {
      debugPrint('[ResourceSearch] yigushi: $e');
    }

    onProgress?.call('渠道：Mp3故事网');
    try {
      addAll(await _yangzhiyi(keyword));
    } catch (e) {
      debugPrint('[ResourceSearch] yangzhiyi: $e');
    }

    onProgress?.call('渠道：slowread 合集');
    try {
      addAll(await _slowread(keyword));
    } catch (e) {
      debugPrint('[ResourceSearch] slowread: $e');
    }

    onProgress?.call('渠道：放空一夏');
    try {
      addAll(await _fangkong(keyword));
    } catch (e) {
      debugPrint('[ResourceSearch] fangkong: $e');
    }

    return found.values.toList();
  }

  Future<List<ResourceHit>> _bilibili(String keyword) async {
    final out = <ResourceHit>[];
    for (final q in {'$keyword 夸克', '$keyword 夸克网盘', '$keyword 有声小说', keyword}) {
      try {
        for (var page = 1; page <= 2; page++) {
          final enc = Uri.encodeComponent(q);
          final url = 'https://api.bilibili.com/x/web-interface/search/type'
              '?search_type=video&keyword=$enc&page=$page&page_size=20';
          final body = await _biliGet(url);
          final data = jsonDecode(body);
          if (data is! Map || data['code'] != 0) break;
          final results = (data['data']?['result'] as List<dynamic>? ?? []);
          if (results.isEmpty) break;
          final sb = StringBuffer();
          for (final r in results) {
            if (r is! Map) continue;
            sb
              ..writeln(r['title'] ?? '')
              ..writeln(r['description'] ?? '')
              ..writeln(r['tag'] ?? '');
          }
          out.addAll(_extract(sb.toString(), 'bilibili'));
          await _sleep(300);
        }
      } catch (e) {
        debugPrint('[ResourceSearch] bilibili「$q」: $e');
      }
      await _sleep(400);
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
        final html = await _text(
            'https://www.yigushi.com/$mod/search.php?kw=${Uri.encodeComponent(q)}');
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
          await _sleep(300);
        }
        await _sleep(300);
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
        await _sleep(300);
      }
      await _sleep(300);
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
