import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'book_source.dart';
import 'online_book_hit.dart';
import 'resource_hit.dart';
import 'webview_fetcher.dart';

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
    if (source.onlineDirPattern != null) {
      _onlineDirRe = RegExp(source.onlineDirPattern!);
    }
    // 会话 Cookie：搜索预热拿到的 PHPSESSID 之类，后续请求必须一直带着，
    // 否则数据接口会返回空。同时把响应的 Set-Cookie 收下来。
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_cookies.isNotEmpty) {
          options.headers.putIfAbsent('Cookie', () => _cookieHeader);
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        _collectCookies(response.headers['set-cookie']);
        handler.next(response);
      },
    ));
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
  RegExp? _onlineDirRe;

  String? _antiBlockCookieCache;

  /// 会话 Cookie（搜索预热/登录态），键值对形式。
  ///
  /// 按站点域名跨引擎实例共享：引擎基本是一次性 new 出来的（搜索/解析章节/
  /// 播放解析各 new 一个），但站点会话（PHPSESSID 等）必须延续，否则
  /// 播放页会因为没会话而 302 回首页，最后解析不到音频。
  static final Map<String, Map<String, String>> _cookieStore = {};

  Map<String, String> get _cookies =>
      _cookieStore.putIfAbsent(_originHost, () => <String, String>{});

  /// 站点域名（用作会话 Cookie 的分组键）。
  String get _originHost {
    final uri = Uri.tryParse(source.urlTemplate);
    final host = uri?.host ?? '';
    return host.isEmpty ? source.id : host;
  }

  /// 被反爬挡住的特征：挑战脚本或过短响应（403 拦截页只有一百多字节）。
  static final RegExp _blockedHint =
      RegExp(r'var reversed|__51guid__|_guard/auto\.js');

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 收集 Set-Cookie（只留键值，丢掉属性）。
  void _collectCookies(List<String>? raw) {
    if (raw == null) return;
    for (final item in raw) {
      final first = item.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      _cookies[first.substring(0, eq)] = first.substring(eq + 1);
    }
  }

  bool _looksBlocked(String html) {
    final text = html.trim();
    return text.length < 200 || _blockedHint.hasMatch(text);
  }

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
          final text = _extractText(await _fetchSearchPage(q, variant));
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
  /// 配了 [BookSource.onlineDirPattern] 时，会再进「完整目录」页（支持分页），
  /// 因为详情页通常只列最新几章。
  Future<OnlineBookDetail> fetchOnlineChapters(String detailUrl) async {
    final detailHtml = await _get(
      detailUrl,
      headers: source.detailHeaders,
      referer: source.onlineReferer ?? _dirOf(detailUrl),
    );
    final dirRe = _onlineDirRe;
    if (dirRe == null) return parseOnlineDetail(detailHtml, detailUrl);

    final rawDir = dirRe.firstMatch(detailHtml)?.group(1) ?? '';
    if (rawDir.isEmpty) {
      debugPrint('[BookSource ${source.id}] 详情页未匹配到完整目录链接，改用详情页章节');
      return parseOnlineDetail(detailHtml, detailUrl);
    }
    final dirUrl = resolveUrl(detailUrl, rawDir);
    final firstPage = await _get(
      dirUrl,
      headers: source.detailHeaders,
      referer: detailUrl,
    );
    final detail = parseOnlineDetail(firstPage, dirUrl);
    final pageParam = source.onlineDirPageParam;
    if (pageParam == null || detail.chapters.isEmpty) {
      return OnlineBookDetail(author: detail.author, chapters: detail.chapters);
    }

    // 目录分页：第一页里一般列着全部页码，取最大值作为末页
    final lastPage = _maxPageOf(firstPage, pageParam)
        .clamp(1, source.onlineDirMaxPages);
    if (lastPage <= 1) {
      return OnlineBookDetail(author: detail.author, chapters: detail.chapters);
    }
    final all = <OnlineChapter>[...detail.chapters];
    final seen = all.map((c) => c.url).toSet();
    // 一次一批地抓（WebView 通道会在页面内并发 fetch；纯 HTTP 通道退化为串行）
    for (var start = 2; start <= lastPage; start += _dirBatchSize) {
      final end = (start + _dirBatchSize - 1).clamp(2, lastPage);
      final pages = [for (var p = start; p <= end; p++) p];
      final urls = [for (final p in pages) _withPage(dirUrl, pageParam, p)];
      final htmls = await _getMany(urls, referer: dirUrl);
      for (var i = 0; i < pages.length && i < htmls.length; i++) {
        final html = htmls[i];
        if (html.isEmpty) {
          debugPrint('[BookSource ${source.id}] 目录第 ${pages[i]} 页为空');
          continue;
        }
        for (final c in parseOnlineDetail(html, urls[i]).chapters) {
          if (seen.add(c.url)) all.add(c);
        }
      }
    }
    debugPrint('[BookSource ${source.id}] 目录共 ${all.length} 集（$lastPage 页）');
    return OnlineBookDetail(author: detail.author, chapters: all);
  }

  /// 目录翻页时一批抓多少页（仅 WebView 通道真正并发；结果要一次性经
  /// JS 桥传回，所以别开太大）。
  static const int _dirBatchSize = 6;

  /// 批量抓取。WebView 通道走页面内并发 fetch，其余退化为串行 HTTP。
  Future<List<String>> _getMany(List<String> urls, {String? referer}) async {
    if (urls.isEmpty) return const [];
    if (source.browserFetch &&
        WebViewFetcher.isSupported &&
        WebViewFetcher.instance.sessionMatches(urls.first)) {
      try {
        final pages = await WebViewFetcher.instance.fetchTextMany(urls);
        // 全空说明会话失效（页面还是 about:blank / 挑战 Cookie 过期）→
        // 退回逐页走 _get（它会导航加载一次把会话建起来）
        if (pages.any((p) => p.isNotEmpty)) return pages;
        debugPrint('[BookSource ${source.id}] 批量抓取全空，退回逐页');
      } catch (e) {
        debugPrint('[BookSource ${source.id}] 批量抓取失败，退回逐页: $e');
      }
    }
    final out = <String>[];
    for (final url in urls) {
      try {
        out.add(await _get(url, headers: source.detailHeaders, referer: referer));
      } catch (e) {
        debugPrint('[BookSource ${source.id}] 抓取 $url 失败: $e');
        out.add('');
      }
      await _sleep();
    }
    return out;
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
    final html = await _get(
      chapterUrl,
      headers: source.detailHeaders,
      referer: source.onlineReferer ?? _dirOf(chapterUrl),
    );
    var m = audioRe.firstMatch(html);
    if (m == null) {
      // 有的站点（如 275听书）播放页要求先有会话，否则 302 回首页 —— 那种响应里
      // 当然没有音频地址。先访问一次站点首页把会话建起来再重试。
      final root = _siteRootOf(chapterUrl);
      if (root.isNotEmpty) {
        debugPrint('[BookSource ${source.id}] 播放页未取到音频，先访问 $root 建会话后重试');
        try {
          await _get(root, headers: source.detailHeaders);
          final retry = await _get(
            chapterUrl,
            headers: source.detailHeaders,
            referer: root,
          );
          m = audioRe.firstMatch(retry);
        } catch (e) {
          debugPrint('[BookSource ${source.id}] 建会话后重试失败: $e');
        }
      }
    }
    if (m == null) {
      throw StateError('播放页里没有匹配到音频地址');
    }
    final url = resolveUrl(chapterUrl, m.group(1) ?? '');
    if (url.isEmpty || !url.startsWith('http')) {
      throw StateError('播放页解析出的音频地址无效');
    }
    return url;
  }

  /// URL 的站点根（如 https://m.i275.com/）。
  String _siteRootOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.host}/';
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

  // ------------------------------------------------------------------
  // 统一抓取入口
  // ------------------------------------------------------------------

  /// 抓一个页面：配了 [BookSource.browserFetch] 的站点走离屏 WebView
  /// （真实浏览器环境，能自己过 JS 挑战），其余走普通 HTTP。
  ///
  /// WebView 失败或被判定为拦截页时回退 HTTP，尽量不整体失败。
  Future<String> _get(
    String url, {
    Map<String, String>? headers,
    String? referer,
  }) async {
    if (source.browserFetch && WebViewFetcher.isSupported) {
      try {
        final html = await _getViaBrowser(url);
        if (!_looksBlocked(html)) return html;
        debugPrint('[BookSource ${source.id}] WebView 拿到疑似拦截页，回退 HTTP: $url');
      } catch (e) {
        debugPrint('[BookSource ${source.id}] WebView 抓取失败，回退 HTTP: $e');
      }
    }
    return _text(url, headers: {
      ...?headers,
      if (referer != null) 'Referer': referer,
    });
  }

  /// WebView 通道：会话可用时走页面内 fetch（带 Cookie、不渲染，快得多），
  /// 否则导航加载（顺带过一次 JS 挑战并建立会话）。
  ///
  /// 判断依据是 WebViewFetcher 自身的状态而不是本对象的字段：引擎基本是一次性
  /// new 出来的，用实例字段会导致每次播放都重新导航过一次挑战（几秒白等）。
  Future<String> _getViaBrowser(String url) async {
    final fetcher = WebViewFetcher.instance;
    if (fetcher.sessionMatches(url)) {
      try {
        final text = await fetcher.fetchText(url);
        if (!_looksBlocked(text)) return text;
      } catch (e) {
        debugPrint('[BookSource ${source.id}] 页面内 fetch 失败，改为导航加载: $e');
      }
    }
    final html = await fetcher.loadHtml(url);
    await _syncBrowserCookies(url);
    return html;
  }

  /// 把 WebView 里的会话 Cookie 收进本地 jar，供 Dio 请求复用。
  Future<void> _syncBrowserCookies(String url) async {
    final raw = await WebViewFetcher.instance.cookieHeader(url);
    if (raw.isEmpty) return;
    for (final part in raw.split('; ')) {
      final eq = part.indexOf('=');
      if (eq > 0) _cookies[part.substring(0, eq)] = part.substring(eq + 1);
    }
  }

  /// 目录页分页：找出站点列出的最大页码（「快速选集」里通常有全部页码）。
  int _maxPageOf(String html, String param) {
    final re = RegExp('[?&]${RegExp.escape(param)}=(\\d+)');
    var max = 1;
    for (final m in re.allMatches(html)) {
      final v = int.tryParse(m.group(1) ?? '');
      if (v != null && v > max) max = v;
    }
    return max;
  }

  /// 给 URL 换上指定页码（保留已有查询参数）。
  String _withPage(String url, String param, int page) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final query = Map<String, String>.from(uri.queryParameters);
    query[param] = '$page';
    return uri.replace(queryParameters: query).toString();
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

  /// 搜索结果的数据来源。
  ///
  /// 有些站点（如 13 听书）搜索结果由页面里的 JS 拉接口渲染，页面本身不含数据，
  /// 且接口要求先有会话 Cookie：这时先用搜索入口请求一次建立会话
  /// （拿 PHPSESSID），再请求 [BookSource.onlineApiTemplate] 取 JSON。
  Future<String> _fetchSearchPage(String keyword, String variant) async {
    final api = source.onlineApiTemplate;
    if (api == null) return _fetchSearch(keyword, variant);
    try {
      await _fetchSearch(keyword, variant); // 预热：建立会话
    } catch (e) {
      debugPrint('[BookSource ${source.id}] 搜索预热失败（继续请求数据接口）: $e');
    }
    return _text(_renderUrl(api, keyword, variant), headers: source.headers);
  }

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
    if (path == null || path.isEmpty) return _normalizeJson(raw);
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

  /// 接口返回的 JSON 里，中文常写成 \uXXXX、斜杠写成 \/（PHP json_encode 的
  /// 默认行为）。不先解开会出现两个问题：
  /// - 书名直接显示成「\u4ece\u9f99\u65cf\u5f00\u59cb」
  /// - URL 里的 \/ 会让 Uri 把路径段当成主机名（Failed host lookup）
  /// Dart 的 jsonDecode 会正常还原，jsonEncode 又不会把非 ASCII 重新转义，
  /// 所以「解码再编码」等于拿到未转义的原文。
  String _normalizeJson(String raw) {
    final head = raw.trimLeft();
    if (head.isEmpty || (head[0] != '{' && head[0] != '[')) return raw;
    try {
      return jsonEncode(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }
}
