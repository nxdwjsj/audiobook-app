import 'package:flutter/material.dart';
import '../widgets/app_page_route.dart';
import 'package:provider/provider.dart';
import '../services/baidu_drive_service.dart';
import '../services/cloud_drive_service.dart';
import '../services/quark_drive_service.dart';
import '../widgets/throttled_navigator.dart';
import 'quark_web_login_page.dart';

/// Page for connecting cloud drive accounts (Baidu / Quark).
class DriveLoginPage extends StatefulWidget {
  const DriveLoginPage({super.key});

  @override
  State<DriveLoginPage> createState() => _DriveLoginPageState();
}

class _DriveLoginPageState extends State<DriveLoginPage> {
  final TextEditingController _baiduAppKeyController = TextEditingController();
  final TextEditingController _baiduTokenController = TextEditingController();
  final TextEditingController _baiduCookieController = TextEditingController();
  final TextEditingController _quarkCookieController = TextEditingController();
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _baiduAppKeyController.dispose();
    _baiduTokenController.dispose();
    _baiduCookieController.dispose();
    _quarkCookieController.dispose();
    super.dispose();
  }

  // 说明：目录缓存（DriveListCache）的清空已收进 Quark/Baidu service 的
  // setCookie / setAccessToken / logout 内部。此前写在本页各调用点，只要
  // 漏一处，新账号就会在 60 秒 TTL 内看到上一个账号的目录。

  Future<void> _saveBaiduAppKey() async {
    final appKey = _baiduAppKeyController.text.trim();
    if (appKey.isEmpty) {
      setState(() => _message = '请输入 AppKey (API Key)');
      return;
    }
    setState(() => _loading = true);
    try {
      final service = context.read<BaiduDriveService>();
      await service.setAppKey(appKey);
      if (mounted) {
        setState(() => _message = '百度 AppKey 已保存，请点击下方按钮开始授权');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AppKey 保存成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '保存失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveBaiduToken() async {
    final token = _baiduTokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _message = '请输入 Access Token');
      return;
    }
    setState(() => _loading = true);
    try {
      final service = context.read<BaiduDriveService>();
      await service.setAccessToken(token);
      if (mounted) {
        setState(() => _message = '百度网盘已连接');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('百度网盘连接成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '连接失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveBaiduCookie() async {
    final cookie = _baiduCookieController.text.trim();
    if (cookie.isEmpty) {
      setState(() => _message = '请输入 BDUSS Cookie');
      return;
    }
    setState(() => _loading = true);
    try {
      final service = context.read<BaiduDriveService>();
      await service.setCookie(cookie);
      if (mounted) {
        setState(() => _message = '百度网盘 Cookie 已保存');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('百度网盘 Cookie 保存成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '保存失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveQuarkCookie() async {
    final cookie = _quarkCookieController.text.trim();
    if (cookie.isEmpty) {
      setState(() => _message = '请输入 Cookie');
      return;
    }
    setState(() => _loading = true);
    try {
      final service = context.read<QuarkDriveService>();
      await service.setCookie(cookie);
      if (mounted) {
        setState(() => _message = '夸克网盘已连接');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('夸克网盘连接成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '连接失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final baiduService = context.watch<BaiduDriveService>();
    final quarkService = context.watch<QuarkDriveService>();

    return Scaffold(
      appBar: AppBar(title: const Text('网盘连接')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_message != null) ...[
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_message!),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Baidu Netdisk
          _DriveCard(
            title: '百度网盘',
            icon: Icons.cloud_rounded,
            color: Colors.blue,
            connected: baiduService.authStatus == AuthStatus.authenticated,
            onLogout: () async {
              await baiduService.logout();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '1. 在百度网盘开放平台 (pan.baidu.com/union) 创建应用，'
                  '获取 AppKey (API Key) 并填到下方',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _baiduAppKeyController,
                  decoration: const InputDecoration(
                    labelText: 'AppKey (API Key)',
                    hintText: '粘贴你自己应用的 AppKey',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _saveBaiduAppKey,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存 AppKey'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '2. 点击下方按钮打开授权页面，登录百度账号并授权',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => baiduService.login(),
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('打开百度授权页面'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '3. 授权后，从浏览器地址栏复制 access_token 并粘贴到下方',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _baiduTokenController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Access Token',
                    hintText: '粘贴从百度授权页面获取的 access_token',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _loading ? null : _saveBaiduToken,
                  child: const Text('保存并验证'),
                ),
                const Divider(height: 28),
                Text(
                  '可选：Cookie（BDUSS）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  '部分接口（如分享链接下载）需要百度 Cookie。'
                  '在浏览器登录百度网盘后，从开发者工具复制 Cookie 中的 BDUSS 值填到下方。',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _baiduCookieController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'BDUSS Cookie',
                    hintText: '粘贴 BDUSS=... 或完整 Cookie 字符串',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _saveBaiduCookie,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存 Cookie'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Quark Drive
          _DriveCard(
            title: '夸克网盘',
            icon: Icons.cloud_done_rounded,
            color: Colors.deepPurple,
            connected: quarkService.authStatus == AuthStatus.authenticated,
            onLogout: () async {
              await quarkService.logout();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () => context.pushThrottled(
                            AppPageRoute(
                              builder: (_) => const QuarkWebLoginPage(),
                            ),
                          ),
                  icon: const Icon(Icons.login),
                  label: const Text('网页登录（自动获取 Cookie）'),
                ),
                const SizedBox(height: 8),
                const Text(
                  '推荐。在应用内打开夸克官方登录页，用「手机号 + 验证码」登录，'
                  '登录成功后自动读取并保存 Cookie，不用抓包。',
                  style: TextStyle(fontSize: 13),
                ),
                const Divider(height: 28),
                Text(
                  '或手动粘贴 Cookie',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  '在电脑浏览器登录 pan.quark.cn，开发者工具里复制完整 Cookie 字符串。',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _quarkCookieController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Cookie',
                    hintText: '粘贴夸克网盘 Cookie',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _loading ? null : _saveQuarkCookie,
                  child: const Text('保存并验证'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DriveCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final bool connected;
  final Future<void> Function() onLogout;
  final Widget child;

  const _DriveCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.connected,
    required this.onLogout,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (connected) ...[
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  const SizedBox(width: 4),
                  const Text('已连接', style: TextStyle(color: Colors.green)),
                  const SizedBox(width: 8),
                  TextButton(onPressed: onLogout, child: const Text('断开')),
                ] else
                  Text('未连接',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
