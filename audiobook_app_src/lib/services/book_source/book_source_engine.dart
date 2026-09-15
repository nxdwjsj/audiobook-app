import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'book_source.dart';
import 'online_book_hit.dart';
import 'resource_hit.dart';

/// 书源规则引擎：把一个 [BookSource] 规则跑成一个「发现渠道」。
///
/// - quark 型：产出 [ResourceHit]（pwdId + 提取码 + 渠道名），
///   与旧版硬编码渠道完全同构，供 ResourceSearchService._discover 统一消费。
/// - online 型：产出 [OnlineBookHit]（详情页链接），加入书架时再经
///   [resolveOnlineChapters] 解析出章节音频直链。
class BookSourceEngine {
  BookSourceEngine(this.source) : _shareRe = RegExp(source.sharePattern) {
    _passcodeRe = RegExp(source.passcodePattern, caseSensitive: false);
    if (source.listLinkPattern != null) {
      _listRe = RegExp(source.listLinkPattern!);
    }
    if (source.onlineBookPattern != null) {
      _onlineBookRe = RegExp(source.onlineBookPattern!);
    }
    if (source.onlineChapterPattern != null) {
      _onlineChapterRe = RegExp(source.onlineChapterPattern!);
    }
    if (source.onlineAudioPattern != null) {
      _onlineAudioRe = RegExp(source.onlineAudioPattern!);
    }
  }

  final BookSource source;

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

  late final RegExp _shareRe;
  late final RegExp _passcodeRe;
  RegExp? _listRe;
  RegExp? _onlineBookRe;
  RegExp? _onlineChapterRe;
  RegExp? _onlineAudioRe;

  String? _antiBlockCookieCache;

  // ------------------------------------------------------------------
  // 查询词生成
  // ------------------------------------------------------------------

  List<String> buildQueries(String keyword) {
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    switch (source.queries) {
      case 'fullPlusQuark':
        // 用 Set 保持顺序去重（「书名 夸克」与「书名」）
        return {'$keyword 夸克', keyword}
            .where((q) => q.trim().isNotEmpty)
            .toList();
      case 'tokens2':
        final t = tokens.take(2).toList();
        return {...t, if (t.length > 1) keyword}.toList();
      case 'tokens3':
        final t = tokens.take(3).toList();
        return {...t, if (t.length > 1) keyword}.toList();
      case 'none':
        return [''];
      case 'full':
      default:
        return [keyword];
    }
  }

  // ------------------------------------------------------------------
  // 主入口
  // ------------------------------------------------------------------

  /// 执行整个发现流程。单页/单文章失败不致命，只跳过。
  ///
  /// quark 型返回分享链接命中；online 型返回 null（改用 [searchOnline]）。
  Future<List<ResourceHit>?> run(String keyword) async {
    if (source.isOnline) return null;
    final out = <ResourceHit>[];
    final seenPwd = <String>{};
    final seenArticle = <String>{};
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final variants = source.variants.isEmpty ? [''] : source.variants;
    for (final q in buildQueries(keyword)) {
      for (final variant in variants) {
        try {
          final html = await _fetchSearch(q, variant);
          final text = _extractText(html);
          await _processPage(
            text, tokens, out, seenPwd, seenArticle);
        } catch (e) {
          debugPrint('[BookSource ${source.id}]「$q/$variant」: $e');
        }
        await _sleep();
      }
    }
    return out;
  }

  // ------------------------------------------------------------------
  // online 型：在线听书站
  // ------------------------------------------------------------------

  /// online 型搜索：请求搜索入口，提取「详情页链接 + 书名」。
  /// 复用 quark 型的请求层（模板渲染 / POST / 反爬）。
  Future<List<OnlineBookHit>> searchOnline(String keyword) async {
    final out = <OnlineBookHit>[];
    final seenUrl = <String>{};
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final bookRe = _onlineBookRe;
    if (bookRe == null) return out;

    final variants = source.variants.isEmpty ? [''] : source.variants;
    for (final q in buildQueries(keyword)) {
      for (final variant in variants) {
        try {
          final html = await _fetchSearch(q, variant);
          final text = _extractText(html);
          for (final m in bookRe.allMatches(text)) {
            final url = resolveUrl(
                source.urlTemplate, m.group(source.onlineBookUrlGroup) ?? '');
            if (url.isEmpty || !seenUrl.add(url)) continue;
            final title = decodeHtmlEntities(
                m.group(source.onlineBookTitleGroup) ?? '');
            if (title.isEmpty) continue;
            if (source.requireTokenInTitle &&
                tokens.isNotEmpty &&
                !tokens.any((t) => title.contains(t))) {
              continue;
            }
            out.add(OnlineBookHit(
              source: source.id,
              detailUrl: url,
              title: title,
            ));
            if (out.length >= source.maxLinks * 2) break;
          }
        } catch (e) {
          debugPrint('[BookSource ${source.id}] online 搜索「$q/$variant」: $e');
        }
        await _sleep();
      }
    }
    return out;
  }

  /// online 型详情页：请求详情页并解析章节列表。
  /// 章节地址可能是音频直链，也可能是播放页（由 [fetchOnlineAudio] 二次解析）。
  Future<OnlineBookDetail> fetchOnlineChapters(String detailUrl) async {
    final html = await _text(detailUrl, headers: {
      ...source.detailHeaders,
      'Referer': source.onlineReferer ?? _dirOf(detailUrl),
    });
    return parseOnlineDetail(html, detailUrl);
  }

  /// 纯解析：详情页 HTML → 章节列表（不请求网络，可单测）。
  OnlineBookDetail parseOnlineDetail(String html, String detailUrl) {
    var chapters = <OnlineChapter>[];
    final seenUrl = <String>{};
    final chapterRe = _onlineChapterRe;
    if (chapterRe != null) {
      for (final m in chapterRe.allMatches(html)) {
        final rawUrl = m.group(source.onlineChapterUrlGroup) ?? '';
        if (rawUrl.isEmpty) continue;
        final url = resolveUrl(detailUrl, rawUrl);
        if (!seenUrl.add(url)) continue;
        final title = decodeHtmlEntities(
            m.group(source.onlineChapterTitleGroup) ?? '');
        chapters.add(OnlineChapter(
          title: title.isEmpty ? '第 ${chapters.length + 1} 集' : title,
          url: url,
        ));
      }
    }
    // 站点把最新章节排在前面（desc）→ 反转成正序
    if (source.onlineChapterOrder == 'desc' && chapters.length > 1) {
      chapters = chapters.reversed.toList();
    }
    String? author;
    final authorRe = source.onlineAuthorPattern;
    if (authorRe != null) {
      final m = RegExp(authorRe).firstMatch(html);
      if (m != null) author = decodeHtmlEntities(m.group(1) ?? '');
    }
    return OnlineBookDetail(author: author, chapters: chapters);
  }

  /// online 型播放页：懒解析出音频直链（播放到该章时才请求）。
  /// 章节地址本身已是音频直链时直接原样返回。
  Future<String> fetchOnlineAudio(String chapterUrl) async {
    if (_isAudioUrl(chapterUrl)) return chapterUrl;
    final audioRe = _onlineAudioRe;
    if (audioRe == null) {
      throw StateError('该源未配置 onlineAudioPattern，无法解析播放页');
    }
    final html = await _text(chapterUrl, headers: {
      ...source.detailHeaders,
      'Referer': source.onlineReferer ?? _dirOf(chapterUrl),
    });
    final m = audioRe.firstMatch(html);
    if (m == null) {
      throw StateError('播放页里没有匹配到音频地址');
    }
    final url = resolveUrl(chapterUrl, m.group(1) ?? '');
    if (url.isEmpty || !url.startsWith('http')) {
      throw StateError('播放页解析出的音频地址无效');
    }
    return url;
  }

  /// 是否「看起来像」音频直链（有音频扩展名）。
  /// 无法 100% 确定也无妨：错判为播放页只是多一次抓取再失败，可重试。
  bool _isAudioUrl(String url) =>
      RegExp(r'\.(mp3|m4a|aac|ogg|wav|flac|m4b|opus)(\?|#|$)',
              caseSensitive: false)
          .hasMatch(url);

  /// 详情页同目录（默认 Referer，防盗链）。
  String _dirOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final segs = uri.pathSegments.toList();
    if (segs.isNotEmpty) segs.removeLast();
    return uri.replace(pathSegments: segs, query: null).toString();
  }

  /// 处理一个搜索页的响应文本。
  Future<void> _processPage(
    String text,
    List<String> tokens,
    List<ResourceHit> out,
    Set<String> seenPwd,
    Set<String> seenArticle,
  ) async {
    if (source.listLinkPattern == null) {
      // 无文章链接规则：直接在响应全文里提取分享链接
      out.addAll(_extractShares(text, seenPwd));
      return;
    }

    // 有文章链接规则：提取 (url, title)，按需跟进详情页
    final articles = <(String, String)>[];
    for (final m in _listRe!.allMatches(text)) {
      final url = m.group(source.urlGroup) ?? '';
      if (url.isEmpty) continue;
      final title = m.group(source.titleGroup) ?? '';
      if (source.requireTokenInTitle &&
          tokens.isNotEmpty &&
          !tokens.any((t) => title.contains(t))) {
        continue;
      }
      if (!seenArticle.add(url)) continue;
      articles.add((url, title));
      if (articles.length >= source.maxLinks) break;
    }

    for (final (url, _) in articles) {
      // 文章链接本身可能就是分享链接（如 slowread 的规则）
      final direct = _extractShares(url, seenPwd);
      if (direct.isNotEmpty) {
        out.addAll(direct);
        continue;
      }
      try {
        final html = await _text(url, headers: source.detailHeaders);
        out.addAll(_extractShares(html, seenPwd));
      } catch (e) {
        debugPrint('[BookSource ${source.id}] 详情页 $url: $e');
      }
      await _sleep();
    }
  }

  /// 从一段文本里提取分享链接（pwdId + 上下文猜提取码）。
  List<ResourceHit> _extractShares(String text, Set<String> seenPwd) {
    final out = <ResourceHit>[];
    for (final m in _shareRe.allMatches(text)) {
      final pwdId = m.group(1) ?? '';
      if (pwdId.isEmpty || !seenPwd.add(pwdId)) continue;
      final start = max(0, m.start - source.passcodeWindow);
      final end = min(text.length, m.end + source.passcodeWindow);
      final window = text.substring(start, end);
      final pwdMatch = _passcodeRe.firstMatch(window);
      out.add(ResourceHit(pwdId,
          passcode: pwdMatch?.group(1), source: source.id));
    }
    return out;
  }

  // ------------------------------------------------------------------
  // 请求层
  // ------------------------------------------------------------------

  /// 请求搜索入口，返回响应文本。
  Future<String> _fetchSearch(String keyword, String variant) async {
    final url = _renderUrl(source.urlTemplate, keyword, variant);
    if (source.method == 'POST' && source.body != null) {
      // 表单值不预编码（Dio 会做 form 编码），只做模板占位符替换
      final data = source.body!.map(
          (k, v) => MapEntry(k, v
              .replaceAll('{{keyEncoded}}', Uri.encodeComponent(keyword))
              .replaceAll('{{key}}', keyword)
              .replaceAll('{{variant}}', variant)));
      final resp = await _dio.post<String>(
        url,
        data: data,
        options: Options(
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
          headers: source.headers,
        ),
      );
      _checkStatus(resp.statusCode);
      return resp.data ?? '';
    }

    if (source.antiBlock == 'bilibili') {
      return _biliGet(url);
    }
    return _text(url, headers: source.headers);
  }

  /// 渲染 URL 模板。{{key}} 自动 URL 编码。
  String _renderUrl(String template, String keyword, String variant) =>
      template
          .replaceAll('{{keyEncoded}}', Uri.encodeComponent(keyword))
          .replaceAll('{{key}}', Uri.encodeComponent(keyword))
          .replaceAll('{{variant}}', variant);

  /// B 站反爬：先拿首页 Cookie（buvid3/buvid4/b_nut），412 时重试。
  Future<String> _biliGet(String url) async {
    var cookie = await _biliCookie();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _text(url, headers: {
          ...source.headers,
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          if (cookie != null) 'Cookie': cookie,
        });
      } catch (e) {
        if (!e.toString().contains('412') || attempt == 2) rethrow;
        _antiBlockCookieCache = null;
        await _sleep();
        cookie = await _biliCookie();
      }
    }
    throw StateError('unreachable');
  }

  Future<String?> _biliCookie() async {
    if (_antiBlockCookieCache != null) return _antiBlockCookieCache;
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
        _antiBlockCookieCache = parts.join('; ');
        return _antiBlockCookieCache;
      }
    } catch (_) {}
    final rnd = Random();
    String hex(int n) => List.generate(
        n, (_) => rnd.nextInt(16).toRadixString(16).toUpperCase()).join();
    _antiBlockCookieCache = 'buvid3=${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-'
        '${hex(12)}infoc; b_nut=${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    return _antiBlockCookieCache;
  }

  Future<String> _text(String url, {Map<String, String>? headers}) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain, headers: headers),
    );
    _checkStatus(resp.statusCode);
    return resp.data ?? '';
  }

  void _checkStatus(int? statusCode) {
    if ((statusCode ?? 0) >= 400) {
      throw Exception('HTTP $statusCode');
    }
  }

  /// 响应可能是 JSON（如 B 站搜索接口）：按规则拼出待提取的纯文本。
  String _extractText(String raw) {
    final path = source.jsonToArray;
    if (path == null || path.isEmpty) return raw;
    try {
      dynamic node = jsonDecode(raw);
      for (final seg in path.split('.')) {
        if (node is Map) {
          node = node[seg];
        } else if (node is List && int.tryParse(seg) != null) {
          node = node[int.parse(seg)];
        } else {
          return raw;
        }
      }
      if (node is! List) return raw;
      final sb = StringBuffer();
      for (final item in node) {
        if (item is! Map) continue;
        for (final f in source.textFields) {
          sb.writeln(item[f] ?? '');
        }
      }
      return sb.toString();
    } catch (_) {
      return raw;
    }
  }

  Future<void> _sleep() => Future.delayed(
      Duration(milliseconds: source.delayMs + Random().nextInt(150)));
}
