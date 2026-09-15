import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 用离屏 WebView 当「内置浏览器」抓页面。
///
/// 有些站点会用 JS 挑战挡普通 HTTP 客户端：服务端先返回一段混淆脚本，
/// 脚本算出挑战 Cookie 后自己 reload，第二次请求才给真实内容；同时还会校验
/// 请求头/指纹（缺 sec-ch-ua 之类的直接 403）。Dio 静态复制请求头过不去，
/// 但真实 WebView 会自己把 JS 跑完、把 Cookie 存好，第二次加载就是真页面。
///
/// 两个能力：
/// - [loadHtml]：导航到目标页，返回渲染后的 HTML（自动等挑战 reload 完成）
/// - [fetchText]：复用同一会话在页面内 fetch 取文本（同源、带 Cookie、快得多）
///
/// 会话（WebView 实例）会复用并延时释放：挑战通过的 Cookie 保留在会话里，
/// 后续分页/播放页不用再过一次挑战。
class WebViewFetcher {
  WebViewFetcher._();

  static final WebViewFetcher instance = WebViewFetcher._();

  /// 手机站 UA：与站点移动端一致，避免被降级到桌面版页面。
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; SM-S9010) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 挑战页特征：命中说明还没过挑战，要等它自己 reload。
  static final RegExp _challengeHint =
      RegExp(r'var reversed|__51guid__|_guard/auto\.js|location\.reload\(');

  /// 一次导航最多容忍几次重载（挑战 + 站点自身的跳转），防止死循环。
  static const int _maxLoads = 4;

  /// 空闲多久后释放 WebView（省内存；Cookie 已由系统 CookieManager 保管，
  /// 挑战 Cookie 还在，下次导航通常不用再过一遍挑战）。
  /// 留得比听一章的时间长一些，避免听书途中切章又重新导航。
  static const Duration _idleTimeout = Duration(minutes: 15);

  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _starting;
  Future<void> _tail = Future.value();
  Timer? _idleTimer;

  /// 是否已经导航加载过真实页面。
  /// 没导航过时页面是 about:blank（origin 为 null），直接 fetch 同源地址会被
  /// CORS 拦；而且挑战 Cookie 也只有导航过一次才在会话里。
  bool _pageLoaded = false;

  /// 当前会话页面所在域名（页面内 fetch 只能同域用）。
  String _loadedHost = '';

  /// 会话是否可用（已加载过站点页面）——调用方可据此直接走页面内 fetch。
  bool get hasLoadedPage => _pageLoaded;

  /// 会话页面是否与 [url] 同域。不同域时页面内 fetch 会被 CORS 拦，
  /// 必须先导航过去（返回 false 让调用方走导航）。
  bool sessionMatches(String url) {
    if (!_pageLoaded) return false;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty && host == _loadedHost;
  }

  /// 轮询「页面内 fetch 是否完成」的间隔。
  static const Duration _pollInterval = Duration(milliseconds: 50);

  void Function(InAppWebViewController, WebUri?)? _onStop;
  void Function(String)? _onError;

  /// 设备上没有 WebView 能力（单元测试/桌面）时返回 false。
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 串行执行：同一时刻只跑一个抓取任务（并发加载既慢又容易触发风控）。
  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<InAppWebViewController> _ensure() async {
    final cached = _controller;
    if (cached != null) return cached;
    final start = _starting ??= Completer<void>();
    if (!start.isCompleted) {
      final webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('about:blank')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent: _ua,
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
          if (!start.isCompleted) start.complete();
        },
        onLoadStop: (controller, url) => _onStop?.call(controller, url),
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame == true) {
            _onError?.call(error.description);
          }
        },
      );
      _webView = webView;
      try {
        await webView.run();
        await start.future.timeout(const Duration(seconds: 15));
      } catch (e) {
        _webView = null;
        _controller = null;
        _starting = null;
        rethrow;
      }
    }
    _touchIdleTimer();
    return _controller!;
  }

  void _touchIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      dispose();
    });
  }

  /// 导航到 [url] 并返回最终 HTML。
  ///
  /// 命中挑战页时会等站点自己 reload；[timeout] 内没拿到真内容就报错。
  Future<String> loadHtml(
    String url, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _serialize(() async {
      final controller = await _ensure();
      final done = Completer<String>();
      var loads = 0;

      Future<void> onStop(InAppWebViewController c, WebUri? u) async {
        loads++;
        var html = '';
        try {
          final raw = await c.evaluateJavascript(
            source: 'document.documentElement.outerHTML',
          );
          html = _unwrapJsString(raw);
        } catch (e) {
          debugPrint('[WebViewFetcher] 读取 DOM 失败: $e');
        }
        // 还在挑战页且还有重载机会 → 挑战脚本会自己 reload，等下一次回调
        if (_challengeHint.hasMatch(html) && loads < _maxLoads) return;
        if (!done.isCompleted) done.complete(html);
      }

      _onStop = onStop;
      _onError = (msg) {
        if (!done.isCompleted) {
          done.completeError(StateError('WebView 加载失败：$msg'));
        }
      };
      final timer = Timer(timeout, () {
        if (!done.isCompleted) {
          done.completeError(TimeoutException('WebView 抓取超时：$url'));
        }
      });

      try {
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        final html = await done.future;
        _pageLoaded = true;
        _loadedHost = Uri.tryParse(url)?.host ?? '';
        return html;
      } finally {
        timer.cancel();
        _onStop = null;
        _onError = null;
      }
    });
  }

  /// 在已加载过页面的会话里 fetch [url] 的文本。
  ///
  /// 同源、自动带会话 Cookie，且不渲染 —— 用于翻页/逐章抓取，比 [loadHtml] 快得多。
  /// 注意：调用前该会话必须已经成功加载过一次该站页面（挑战 Cookie 才会存在，
  /// 页面 origin 也才会是站点域名，否则同源 fetch 会被拦）。
  ///
  /// 插件不会等待 JS Promise，所以这里用「发起 fetch → 结果写全局变量 → 轮询」
  /// 的方式取结果。
  Future<String> fetchText(
    String url, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _serialize(() async {
      final controller = await _ensure();
      final key = '__tt_fetch_${DateTime.now().microsecondsSinceEpoch}';
      await controller.evaluateJavascript(source: '''
window.$key = null;
(function () {
  fetch(${jsonEncode(url)}, { credentials: 'include' })
    .then(function (r) { return r.text(); })
    .then(function (t) { window.$key = { ok: true, body: t }; })
    .catch(function (e) { window.$key = { ok: false, body: String(e) }; });
})();
''');

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_pollInterval);
        final raw = await controller.evaluateJavascript(
          source: 'window.$key ? JSON.stringify(window.$key) : ""',
        );
        final result = _tryDecodeMap(_unwrapJsString(raw));
        if (result == null) continue;
        await controller.evaluateJavascript(source: 'window.$key = null;');
        if (result['ok'] == true) return result['body']?.toString() ?? '';
        throw StateError('页面内 fetch 失败：${result['body']}');
      }
      throw TimeoutException('页面内 fetch 超时：$url');
    });
  }

  /// 一次抓取多个同源页面（页面内分批并发）。
  ///
  /// 比逐个 [fetchText] 快得多：一次 Dart↔JS 往返就能拿回一批页面，
  /// 适合「同一个模板翻几十页」的目录抓取。单页失败返回空串，不影响其它页。
  Future<List<String>> fetchTextMany(
    List<String> urls, {
    int batchSize = 6,
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (urls.isEmpty) return Future.value(const <String>[]);
    return _serialize(() async {
      final controller = await _ensure();
      final key = '__tt_many_${DateTime.now().microsecondsSinceEpoch}';
      await controller.evaluateJavascript(source: '''
window.$key = null;
(function () {
  var urls = ${jsonEncode(urls)};
  var out = [];
  var size = $batchSize;
  function step(i) {
    if (i >= urls.length) {
      window.$key = { ok: true, body: JSON.stringify(out) };
      return;
    }
    var chunk = urls.slice(i, i + size);
    Promise.all(chunk.map(function (u) {
      return fetch(u, { credentials: 'include' })
        .then(function (r) { return r.text(); })
        .catch(function () { return ''; });
    })).then(function (part) {
      out = out.concat(part);
      step(i + size);
    });
  }
  step(0);
})();
''');

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_pollInterval);
        final raw = await controller.evaluateJavascript(
          source: 'window.$key ? JSON.stringify(window.$key) : ""',
        );
        final result = _tryDecodeMap(_unwrapJsString(raw));
        if (result == null) continue;
        await controller.evaluateJavascript(source: 'window.$key = null;');
        if (result['ok'] != true) {
          throw StateError('页面内批量 fetch 失败：${result['body']}');
        }
        final decoded = jsonDecode(result['body']?.toString() ?? '');
        if (decoded is List) {
          return [for (final item in decoded) item?.toString() ?? ''];
        }
        return const <String>[];
      }
      throw TimeoutException('页面内批量 fetch 超时（${urls.length} 页）');
    });
  }

  /// WebView 的 JS 返回值可能是 JSON 字符串字面量（带引号与转义），
  /// 也可能是已解析好的原始字符串 —— 两种都还原成原始文本。
  static String _unwrapJsString(Object? raw) {
    if (raw == null) return '';
    final text = raw.toString();
    if (text.isEmpty || text == 'null') return '';
    if (text.startsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return text;
  }

  /// 把 JS 返回的 JSON 解成 Map（兼容「已被包成字符串」的一层）。
  static Map<String, dynamic>? _tryDecodeMap(String text) {
    if (text.isEmpty) return null;
    try {
      final value = jsonDecode(text);
      if (value is Map) return value.cast<String, dynamic>();
      if (value is String && value.isNotEmpty) {
        final inner = jsonDecode(value);
        if (inner is Map) return inner.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  /// 读取会话里某域名下的 Cookie（挑战 Cookie 就在这儿），
  /// 供需要走 Dio 的请求复用。
  Future<String> cookieHeader(String url) async {
    if (!isSupported) return '';
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri(url));
      return cookies
          .where((c) => c.name.isNotEmpty)
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
    } catch (e) {
      debugPrint('[WebViewFetcher] 读取 Cookie 失败: $e');
      return '';
    }
  }

  /// 释放 WebView（会话 Cookie 由系统 CookieManager 保管，不影响下次使用）。
  Future<void> dispose() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final webView = _webView;
    _webView = null;
    _controller = null;
    _starting = null;
    _onStop = null;
    _onError = null;
    _pageLoaded = false;
    _loadedHost = '';
    if (webView != null) {
      try {
        await webView.dispose();
      } catch (e) {
        debugPrint('[WebViewFetcher] 释放失败: $e');
      }
    }
  }
}