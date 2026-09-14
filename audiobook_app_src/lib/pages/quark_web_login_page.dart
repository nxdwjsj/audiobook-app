import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/quark_drive_service.dart';

/// 通过内置 WebView 打开夸克官方登录页，登录完成后自动读取 Cookie。
///
/// 相比让用户手动抓包复制 Cookie，这里用的是官方登录页本身：
/// 不依赖任何逆向接口，夸克改版也不会失效。
/// 页面上可以直接用「手机号 + 验证码」登录，不需要第二台设备扫码。
class QuarkWebLoginPage extends StatefulWidget {
  const QuarkWebLoginPage({super.key});

  @override
  State<QuarkWebLoginPage> createState() => _QuarkWebLoginPageState();
}

class _QuarkWebLoginPageState extends State<QuarkWebLoginPage> {
  static const String _loginUrl = 'https://pan.quark.cn/account/login';

  /// 必须伪装成桌面浏览器：`account/login` 在手机 UA 下会被重定向到
  /// 「夸克网盘 · 立即下载」推广页，根本看不到登录表单。
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 读取 Cookie 时覆盖的域名：夸克把会话 Cookie 挂在 .quark.cn 上。
  static const List<String> _cookieUrls = [
    'https://pan.quark.cn/',
    'https://drive-pc.quark.cn/',
    'https://uop.quark.cn/',
  ];

  /// 登录后才会出现的会话字段，仅用于给出更友好的提示。
  static const Set<String> _sessionCookieNames = {'__pus', '__puus', '__uid'};

  InAppWebViewController? _controller;
  double _progress = 0;
  bool _busy = false;
  String? _error;

  /// 最近一次读取时是否见到过会话字段，用来区分「还没登录」和「Cookie 无效」。
  bool _sawSessionCookie = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('夸克网盘登录'),
        actions: [
          IconButton(
            tooltip: '重新加载登录页',
            onPressed: () => _controller?.loadUrl(
              urlRequest: URLRequest(url: WebUri(_loginUrl)),
            ),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(
            value: _progress >= 1.0 ? null : _progress,
            minHeight: 2,
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                useHybridComposition: true,
                transparentBackground: false,
                userAgent: _desktopUserAgent,
                // 桌面版登录页在窄屏上会被整体缩放，保证表单可用
                useWideViewPort: true,
                loadWithOverviewMode: true,
                supportZoom: true,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
              onLoadStop: (controller, url) {
                final u = url?.toString() ?? '';
                // 登录成功后会跳回网盘首页，此时静默尝试读取一次
                if (u.contains('pan.quark.cn') && !u.contains('login')) {
                  _readCookie(silent: true);
                }
              },
            ),
          ),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '提示：在页面里用「手机号 + 验证码」登录即可，登录成功后会自动读取 Cookie。'
              '若没有自动完成，点下方按钮手动读取。',
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : () => _readCookie(silent: false),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_done),
              label: Text(_busy ? '正在读取…' : '我已登录，读取 Cookie'),
            ),
          ],
        ),
      ),
    );
  }

  /// 读取 WebView 里的 Cookie 并交给 QuarkDriveService 校验。
  /// [silent] 为 true 时不报「未登录」之类的错误（自动触发用）。
  Future<void> _readCookie({required bool silent}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // 先取好 provider，避免 await 之后再碰 context
      final service = context.read<QuarkDriveService>();

      final cookies = <String, String>{};
      for (final url in _cookieUrls) {
        final list = await CookieManager.instance().getCookies(
          url: WebUri(url),
        );
        for (final c in list) {
          if (c.name.isEmpty) continue;
          cookies[c.name] = c.value;
        }
      }

      final hasSession =
          cookies.keys.any(_sessionCookieNames.contains);
      if (cookies.isEmpty) {
        if (!silent) {
          setState(() => _error = '还没读到 Cookie，请先在页面里完成登录');
        }
        return;
      }

      _sawSessionCookie = hasSession;

      final cookieString =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

      // 交给 service 校验，通过才会落盘；不通过会抛错
      await service.setCookie(cookieString);

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _sawSessionCookie
            ? '保存失败：$e'
            : '还没检测到登录状态，请在页面里完成登录后重试';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}