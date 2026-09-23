import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/baidu_drive_service.dart';
import 'package:audiobook_app/services/cloud_drive_service.dart';
import 'package:audiobook_app/services/http/network_client.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 百度网盘 `init()` 的「同源 Bug」回归：本地有 token / cookie 就无条件置
/// authenticated、从不校验 —— 就是刚给夸克修掉的「永久假已连接」。
///
/// 修复后应与夸克用同一套容错策略：乐观置位 + 后台校验 + 事后纠正；
/// 超时 / 断网一律保持 authenticated，只有明确失效才 expired。
///
/// 全部走 dio 拦截器伪造响应，不依赖真实网络。
class _FakeStorage extends StorageService {
  _FakeStorage({this.token, this.cookie});

  String? token;
  String? cookie;

  @override
  String? getBaiduToken() => token;

  @override
  String? getBaiduCookie() => cookie;
}

/// 用拦截器直接 resolve 伪造响应，避免真的发请求。
Dio _fakeDio(Response<dynamic> Function(RequestOptions options) respond) {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(respond(options)),
  ));
  return dio;
}

/// 拦截请求但**永不响应**，用于验证「init 不等待网络」。
Dio _hangingDio() {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      // 故意既不 resolve 也不 reject
    },
  ));
  return dio;
}

Response<dynamic> _json(
  RequestOptions options, {
  int status = 200,
  Object? data,
}) =>
    Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: data,
    );

/// 执行 init 并**等后台校验结束**（B4 后 init 不再阻塞等待网络）。
Future<void> initSettled(BaiduDriveService service) async {
  await service.init();
  await service.startupCheckDone;
}

void main() {
  group('百度 init 冷启动校验（同源 Bug 修复）', () {
    test('无 token 且无 cookie → 未连接（不乐观置位）', () async {
      final s = BaiduDriveService(
        _FakeStorage(),
        dio: _fakeDio((o) => _json(o, data: {'errno': 0})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.unauthenticated);
    });

    test('token 有效 → 已连接', () async {
      final s = BaiduDriveService(
        _FakeStorage(token: 'good-token'),
        dio: _fakeDio((o) => _json(o, data: {'errno': 0, 'baidu_name': 'me'})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.authenticated);
    });

    test('token 失效（errno=-6）→ 过期（修复前是永久已连接）', () async {
      final s = BaiduDriveService(
        _FakeStorage(token: 'bad-token'),
        dio: _fakeDio((o) => _json(o, data: {'errno': -6})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);
    });

    test('token 接口返回非 JSON 登录页（HTTP 200）→ 过期', () async {
      final s = BaiduDriveService(
        _FakeStorage(token: 'bad-token'),
        dio: _fakeDio((o) => _json(o, data: '<html>请登录</html>')),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);
    });

    test('网络不通 → 保持已连接，不误导用户换凭据', () async {
      final s = BaiduDriveService(
        _FakeStorage(token: 'good-token'),
        dio: _fakeDio((o) => throw DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
              error: 'no network',
            )),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.authenticated);
    });

    test('只有 cookie（无 token）且有效 → 已连接', () async {
      final s = BaiduDriveService(
        _FakeStorage(cookie: 'BDUSS=abc'),
        dio: _fakeDio((o) => _json(o, data: {'errno': 0})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.authenticated);
    });

    test('只有 cookie 且失效（errno≠0）→ 过期', () async {
      final s = BaiduDriveService(
        _FakeStorage(cookie: 'BDUSS=bad'),
        dio: _fakeDio((o) => _json(o, data: {'errno': 2})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);
    });

    test('init 不等待网络：有凭据立即乐观置位，后台再校验', () async {
      final s = BaiduDriveService(
        _FakeStorage(token: 'good-token'),
        dio: _hangingDio(),
      );
      final sw = Stopwatch()..start();
      await s.init().timeout(const Duration(seconds: 2));
      sw.stop();
      // 乐观置位：UI 启动即可用，不卡在启动页
      expect(s.authStatus, AuthStatus.authenticated);
      // 远小于 _initVerifyTimeout（5s），证明 init 没有同步等待网络
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      // 收尾：drain 掉后台 5s 超时，避免遗留 pending 定时器
      await s.startupCheckDone.timeout(const Duration(seconds: 10));
      // 超时视为「无法确认」而非「失效」，仍保持已连接
      expect(s.authStatus, AuthStatus.authenticated);
    });
  });
}
