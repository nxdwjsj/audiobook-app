// 夸克扫码登录原型（独立脚本，不参与 App 打包）。
//
// 流程：
//   1. 申请二维码 token       GET https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin
//   2. 拼出二维码内容 URL       https://su.quark.cn/4_eMHBJ?token=...
//   3. 生成二维码 SVG 并用浏览器打开 → 手机夸克 App 扫一扫（或扫一扫→相册选图）
//   4. 轮询扫码状态            GET https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken
//   5. 用 service_ticket 换 Cookie   GET https://pan.quark.cn/account/info?st=...&lw=scan
//
// 用法：
//   dart run tool/quark_login.dart                 # 默认写到 ~/.quark_cookie.txt
//   dart run tool/quark_login.dart --out out.txt   # 指定输出路径
//   dart run tool/quark_login.dart --timeout 120
//
// 注意：Cookie 等同于账号登录态，脚本不会把 Cookie 内容打印到日志，只写入文件。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:qr/qr.dart';

const String _ua =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// 登录流程
// ---------------------------------------------------------------------------

class QuarkQrLogin {
  QuarkQrLogin() {
    _dio.options.headers.addAll(_commonHeaders);
    _plainDio.options.headers.addAll(_commonHeaders);
    _dio.interceptors.add(_CookieJar());
  }

  static const Map<String, String> _commonHeaders = {
    'User-Agent': _ua,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    // 官方前端是在 pan.quark.cn 页面上发起的，必须伪装成同站请求
    'Origin': 'https://pan.quark.cn',
    'Referer': 'https://pan.quark.cn/',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': 'same-site',
  };

  /// 登录阶段用的实例：带 Cookie 罐（官方前端是浏览器，天然带 Cookie）。
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 600,
  ));

  /// 换 Cookie 阶段用的实例：自己管跳转与 Cookie，不共用罐。
  final Dio _plainDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 600,
  ));

  /// 预热后会话里拿到了多少个 Cookie 字段（诊断用：0 说明会话没建立）。
  int get sessionCookieCount => _dio.interceptors
      .whereType<_CookieJar>()
      .fold(0, (_, jar) => jar.count);

  /// 先访问一次夸克登录页，让 Cookie 罐拿到会话 Cookie。
  /// 官方前端跑在浏览器里，申请 token 时天然带着这些 Cookie；
  /// 裸调接口拿到的 token 服务端不认，扫码会提示「二维码已失效」。
  Future<void> warmUp() async {
    for (final url in [
      'https://pan.quark.cn/account/login',
      'https://pan.quark.cn/',
    ]) {
      try {
        await _dio.get(url, options: Options(responseType: ResponseType.plain));
      } catch (_) {
        // 预热失败不致命，继续走
      }
    }
  }

  /// 第 1 步：申请二维码 token。官方实现不带任何参数。
  Future<String> fetchQrToken() async {
    final resp = await _dio.get(
      'https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin',
    );
    final data = resp.data;
    if (data is! Map) {
      throw Exception('申请二维码返回非 JSON（HTTP ${resp.statusCode}）');
    }
    if (data['status'] != 2000000) {
      throw Exception(
          '申请二维码失败: status=${data['status']} msg=${data['message']}');
    }
    final token = data['data']?['members']?['token']?.toString();
    if (token == null || token.isEmpty) {
      throw Exception('返回里没有 token: $data');
    }
    return token;
  }

  /// 第 2 步：二维码里要编码的内容。
  /// 必须与官方前端拼出的字符串完全一致：uc_biz_str 不做百分号编码，
  /// 否则夸克 App 解析不出参数，会直接判定二维码失效。
  String buildQrContent(String token) {
    return 'https://su.quark.cn/4_eMHBJ'
        '?token=$token'
        '&client_id=532'
        '&ssb=weblogin'
        '&uc_param_str='
        '&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
  }

  /// 第 4 步：查一次扫码状态。官方实现只带 token。
  Future<PollResult> poll(String token) async {
    final resp = await _dio.get(
      'https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken',
      queryParameters: {'token': token},
    );
    final data = resp.data;
    if (data is! Map) {
      return const PollResult(PollState.waiting, null, '响应非 JSON', null);
    }

    final status = (data['status'] as num?)?.toInt();
    final message = (data['message'] ?? '').toString();
    final ticket = data['data']?['members']?['service_ticket']?.toString();

    if (status == 2000000 && message == 'ok' && ticket != null) {
      return PollResult(PollState.confirmed, ticket, message, status);
    }
    // 50004001 = 还没扫码；其余 5000400x 为明确失败/过期
    if (status == 50004001) {
      return PollResult(PollState.waiting, null, '等待扫码', status);
    }
    if (status == 50004002 ||
        status == 50004003 ||
        status == 50004004 ||
        status == 50004005 ||
        message.contains('expired')) {
      return PollResult(PollState.failed, null, 'status=$status $message', status);
    }
    // 已扫码、待确认（状态码既非等待也非失败）
    return PollResult(PollState.scanned, null, 'status=$status $message', status);
  }

  /// 第 5 步：service_ticket 换 Cookie。
  /// 手动跟跳转，逐跳收集 Set-Cookie，等价于一个最小 Cookie 罐。
  Future<LoginResult> exchangeCookie(String ticket) async {
    final jar = <String, String>{};
    var url = Uri.parse('https://pan.quark.cn/account/info')
        .replace(queryParameters: {'st': ticket, 'lw': 'scan'})
        .toString();

    Map<String, dynamic>? body;

    for (var hop = 0; hop < 6; hop++) {
      final resp = await _plainDio.get(
        url,
        options: Options(
          followRedirects: false,
          headers: {
            if (jar.isNotEmpty)
              'Cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
          },
        ),
      );
      _absorbCookies(resp.headers['set-cookie'], jar);

      final status = resp.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final loc = resp.headers.value('location');
        if (loc == null || loc.isEmpty) break;
        url = Uri.parse(url).resolve(loc).toString();
        continue;
      }
      if (resp.data is Map) body = (resp.data as Map).cast<String, dynamic>();
      break;
    }

    if (jar.isEmpty) {
      throw Exception('没有拿到任何 Cookie，登录可能未完成');
    }

    return LoginResult(
      cookie: jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
      cookieNames: jar.keys.toList(),
      accountInfo: body,
    );
  }

  void _absorbCookies(List<String>? setCookies, Map<String, String> jar) {
    if (setCookies == null) return;
    for (final raw in setCookies) {
      // 只取 name=value，后面可能跟 Expires（含逗号）、Path、HttpOnly 等
      final pair = raw.split(';').first.trim();
      final idx = pair.indexOf('=');
      if (idx <= 0) continue;
      final name = pair.substring(0, idx).trim();
      final value = pair.substring(idx + 1).trim();
      jar[name] = value;
    }
  }
}

/// 极简 Cookie 罐：把响应里的 Set-Cookie 记下来，后续请求带上。
/// 官方前端跑在浏览器里天然带 Cookie，脚本必须自己补上这一层。
class _CookieJar extends Interceptor {
  final Map<String, String> _jar = {};

  int get count => _jar.length;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_jar.isNotEmpty && !options.headers.containsKey('Cookie')) {
      options.headers['Cookie'] =
          _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final setCookies = response.headers['set-cookie'];
    if (setCookies != null) {
      for (final raw in setCookies) {
        final pair = raw.split(';').first.trim();
        final idx = pair.indexOf('=');
        if (idx <= 0) continue;
        _jar[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
      }
    }
    handler.next(response);
  }
}

enum PollState { waiting, scanned, confirmed, failed }

class PollResult {
  const PollResult(this.state, this.ticket, this.message, this.rawStatus);
  final PollState state;
  final String? ticket;
  final String message;
  final int? rawStatus;
}

class LoginResult {
  const LoginResult({
    required this.cookie,
    required this.cookieNames,
    this.accountInfo,
  });
  final String cookie;
  final List<String> cookieNames;
  final Map<String, dynamic>? accountInfo;

  String? get nickname =>
      accountInfo?['data']?['nickname']?.toString() ??
      accountInfo?['data']?['nickName']?.toString();
}

// ---------------------------------------------------------------------------
// 二维码渲染
// ---------------------------------------------------------------------------

/// 用纯文本 SVG 渲染二维码，浏览器打开即可扫。
String renderQrSvg(String data, {int scale = 8, int border = 4}) {
  final code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(code);
  final n = code.moduleCount;
  final size = (n + border * 2) * scale;

  final sb = StringBuffer()
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" '
        'width="$size" height="$size" viewBox="0 0 $size $size">')
    ..writeln('<rect width="$size" height="$size" fill="#ffffff"/>');

  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (!image.isDark(r, c)) continue;
      final x = (c + border) * scale;
      final y = (r + border) * scale;
      sb.writeln('<rect x="$x" y="$y" width="$scale" height="$scale" '
          'fill="#000000"/>');
    }
  }
  sb.writeln('</svg>');
  return sb.toString();
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts.containsKey('help')) {
    _printUsage();
    return;
  }

  final timeout = int.tryParse(opts['timeout'] ?? '') ?? 180;
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  final outPath = opts['out'] ?? '$home/.quark_cookie.txt';
  // 每次用不同文件名：浏览器里可能还开着上一次的二维码标签页，同名会扫错
  final qrPath = opts['qr'] ??
      '$home/.quark_login_qr_${DateTime.now().millisecondsSinceEpoch}.svg';

  // 清掉旧版固定文件名的二维码，避免误扫
  final legacyQr = File('$home/.quark_login_qr.svg');
  if (legacyQr.existsSync()) legacyQr.deleteSync();

  final login = QuarkQrLogin();

  print('== 第 0 步：访问夸克登录页建立会话 ==');
  await login.warmUp();
  print('  会话 Cookie 字段数: ${login.sessionCookieCount}');

  print('== 第 1 步：申请二维码 ==');
  final token = await login.fetchQrToken();
  print('  token: ${token.substring(0, token.length.clamp(0, 12))}...');

  print('== 第 2 步：生成二维码 ==');
  final content = login.buildQrContent(token);
  await File(qrPath).writeAsString(renderQrSvg(content));
  print('  二维码内容: $content');
  print('  已写入: $qrPath');

  try {
    await Process.run('cmd', ['/c', 'start', '', qrPath]);
    print('  已用默认程序打开，请用夸克 App 扫一扫（支持相册选图）');
  } catch (e) {
    print('  自动打开失败（$e），请手动打开上面那个文件');
  }

  print('== 第 3 步：等待扫码确认（超时 ${timeout}s）==');
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  PollResult? result;
  var scannedNotified = false;
  int? lastStatus;

  while (DateTime.now().isBefore(deadline)) {
    final r = await login.poll(token);
    if (r.state == PollState.confirmed) {
      result = r;
      break;
    }
    if (r.state == PollState.failed) {
      print('  失败: ${r.message}');
      break;
    }
    if (r.state == PollState.scanned && !scannedNotified) {
      print('  已扫码，等待你在手机上点确认...');
      scannedNotified = true;
    }
    // 状态码变化时打一行，便于观察扫码各阶段的真实状态码
    if (r.rawStatus != lastStatus) {
      print('  [status=${r.rawStatus} ${r.message}]');
      lastStatus = r.rawStatus;
    }
    stdout.write(r.state == PollState.scanned ? ' *' : ' .');
    await Future.delayed(const Duration(seconds: 2));
  }

  if (result?.ticket == null) {
    print('\n未完成扫码（超时或二维码过期）。重新运行即可换新二维码。');
    exit(1);
  }

  print('\n== 第 4 步：换取 Cookie ==');
  final login2 = await login.exchangeCookie(result!.ticket!);
  print('  拿到 ${login2.cookieNames.length} 个 Cookie 字段: '
      '${login2.cookieNames.join(', ')}');
  print('  Cookie 长度: ${login2.cookie.length} 字符');
  if (login2.nickname != null) {
    print('  登录账号: ${login2.nickname}');
  }

  await File(outPath).writeAsString(login2.cookie);
  print('  Cookie 已写入: $outPath');
  print('  （脚本不打印 Cookie 内容；该文件等同账号登录态，请勿外传）');

  print('\n== 第 5 步：验证 Cookie 是否可用 ==');
  final ok = await verifyCookie(login2.cookie);
  print(ok ? '  验证通过：Cookie 可正常访问夸克接口' : '  验证失败：Cookie 可能不完整');
  exit(ok ? 0 : 2);
}

/// 用拿到的 Cookie 打一个需要登录的接口，确认真的能用。
Future<bool> verifyCookie(String cookie) async {
  final dio = Dio(BaseOptions(
    validateStatus: (s) => s != null && s < 600,
    headers: {
      'User-Agent': _ua,
      'Referer': 'https://pan.quark.cn/',
      'Cookie': cookie,
    },
    connectTimeout: const Duration(seconds: 15),
  ));
  try {
    final resp = await dio.get(
      'https://drive-pc.quark.cn/1/clouddrive/config',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
    );
    final data = resp.data;
    if (data is Map) {
      print('  config 接口: code=${data['code']} msg=${data['message']}');
      return data['code'] == 0;
    }
    return false;
  } catch (e) {
    print('  验证请求异常: $e');
    return false;
  }
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (key == 'help') {
      out['help'] = 'true';
      continue;
    }
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[i + 1];
      i++;
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

void _printUsage() {
  print('''
夸克扫码登录（原型）

用法:
  dart run tool/quark_login.dart [选项]

选项:
  --out <路径>      Cookie 输出路径，默认 ~/.quark_cookie.txt
  --qr <路径>       二维码 SVG 输出路径，默认 ~/.quark_login_qr.svg
  --timeout <秒>    等待扫码超时，默认 180
  --help            显示帮助

说明:
  脚本不打印 Cookie 内容，只写入文件。Cookie 等同账号登录态，请勿外传。
''');
}