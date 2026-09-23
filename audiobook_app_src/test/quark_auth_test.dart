import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/cloud_drive_service.dart';
import 'package:audiobook_app/services/http/network_client.dart';
import 'package:audiobook_app/services/quark_drive_service.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 只覆盖与本次修复相关的判定逻辑：
/// - 冷启动（init）不再无条件认定「已连接」
/// - HTTP 401/403/412 与「响应非 JSON」都要能被识别为需要重新连接
/// - 网络异常不能误导用户去换 Cookie
///
/// 全部走 dio 拦截器伪造响应，不依赖真实网络。

/// 本地存 Cookie 的假存储：绕开 Hive（测试里不初始化 Hive）。
class _FakeStorage extends StorageService {
  _FakeStorage(this.cookie);

  String cookie;
  String? saved;

  @override
  String? getQuarkCookie() => cookie.isEmpty ? null : cookie;

  @override
  Future<void> saveQuarkCookie(String value) async => saved = value;
}

/// 用拦截器直接 resolve 伪造响应，避免真的发请求。
Dio _fakeDio(Response<dynamic> Function(RequestOptions options) respond) {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(respond(options)),
  ));
  return dio;
}

/// 构造一个带假网络的 QuarkDriveService。[respond] 按 path 决定返回什么。
QuarkDriveService _serviceWith(
  Response<dynamic> Function(RequestOptions options) respond, {
  String cookie = 'test-cookie',
}) {
  return QuarkDriveService(_FakeStorage(cookie), dio: _fakeDio(respond));
}

Response<dynamic> _json(
  RequestOptions options, {
  int status = 200,
  Object? data,
}) {
  return Response<dynamic>(
    requestOptions: options,
    statusCode: status,
    data: data,
  );
}

/// 拦截请求但**永不响应**，用于验证「init 不等待网络」。
Dio _hangingDio() {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      // 故意既不 resolve 也不 reject：请求永远挂起
    },
  ));
  return dio;
}

/// 账户接口「有效」的响应。
Response<dynamic> _accountOk(RequestOptions options) =>
    _json(options, data: {'code': 0, 'data': {'nickname': 'tester'}});

/// 执行 init 并**等后台校验结束**。
///
/// B4 之后 [QuarkDriveService.init] 是「乐观置位 + 后台校验」，返回时校验通常
/// 还没跑完；凡是要断言「最终登录态」的用例都必须先等 [startupCheckDone]。
Future<void> initSettled(QuarkDriveService service) async {
  await service.init();
  await service.startupCheckDone;
}

void main() {
  group('失效判定表（静态谓词）', () {
    test('HTTP 401/403/412 视为需要重新连接', () {
      expect(QuarkDriveService.isAuthExpiredStatus(401), isTrue);
      expect(QuarkDriveService.isAuthExpiredStatus(403), isTrue);
      // 412 是下载 CDN 对无有效 Cookie 的响应，是本 bug 的关键漏网路径
      expect(QuarkDriveService.isAuthExpiredStatus(412), isTrue);
    });

    test('其他 HTTP 状态码不算登录失效', () {
      expect(QuarkDriveService.isAuthExpiredStatus(200), isFalse);
      expect(QuarkDriveService.isAuthExpiredStatus(404), isFalse);
      expect(QuarkDriveService.isAuthExpiredStatus(500), isFalse);
    });

    test('业务码 401/403/412 与常见登录失效码视为失效', () {
      expect(QuarkDriveService.isAuthExpiredCode(401), isTrue);
      expect(QuarkDriveService.isAuthExpiredCode(403), isTrue);
      expect(QuarkDriveService.isAuthExpiredCode(412), isTrue);
      expect(QuarkDriveService.isAuthExpiredCode(10001), isTrue);
      expect(QuarkDriveService.isAuthExpiredCode(41008), isTrue);
    });

    test('普通业务码不算登录失效', () {
      expect(QuarkDriveService.isAuthExpiredCode(0), isFalse);
      expect(QuarkDriveService.isAuthExpiredCode(-1), isFalse);
      expect(QuarkDriveService.isAuthExpiredCode(10002), isFalse);
    });
  });

  group('init 冷启动校验', () {
    test('本地没有 Cookie → 未连接', () async {
      final service = QuarkDriveService(_FakeStorage(''), dio: _fakeDio(_accountOk));
      await initSettled(service);
      expect(service.authStatus, AuthStatus.unauthenticated);
    });

    test('Cookie 仍有效 → 已连接', () async {
      final service = _serviceWith(_accountOk);
      await initSettled(service);
      expect(service.authStatus, AuthStatus.authenticated);
    });

    test('init 不等待网络：有 Cookie 立即乐观置位，后台再校验', () async {
      // dio 永不响应，模拟慢网 / 服务端卡死。
      final service =
          QuarkDriveService(_FakeStorage('test-cookie'), dio: _hangingDio());
      final sw = Stopwatch()..start();
      // 关键：init 必须立刻返回（B4 之前会阻塞到 5s 校验超时）。
      await service.init().timeout(const Duration(seconds: 2));
      sw.stop();
      // 乐观置位：UI 启动即可认为「已连接」，不卡在启动页。
      expect(service.authStatus, AuthStatus.authenticated);
      // 远小于 _initVerifyTimeout（5s），证明 init 没有同步等待网络。
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      // 收尾：把后台的 5s 超时跑完，避免测试结束后遗留 pending 定时器。
      await service.startupCheckDone.timeout(const Duration(seconds: 10));
      // 超时视为「无法确认」而非「失效」，仍保持已连接（不误导用户换 Cookie）。
      expect(service.authStatus, AuthStatus.authenticated);
    });

    test('Cookie 已退化（返回 HTML 登录页，非 JSON）→ 过期', () async {
      // 这正是「显示已连接但播不了」的场景：本地有 Cookie 字符串，
      // 但服务端已不认，返回的是登录页而不是 JSON。
      final service = _serviceWith(
        (o) => Response<dynamic>(
          requestOptions: o,
          statusCode: 200,
          data: '<!DOCTYPE html><html><body>请重新登录</body></html>',
        ),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);
    });

    test('账户接口返回登录失效业务码 → 过期', () async {
      final service = _serviceWith(
        (o) => _json(o, data: {'code': 41008, 'message': '登录凭证已过期'}),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);
    });

    test('账户接口返回 HTTP 401 → 过期', () async {
      final service = _serviceWith(
        (o) => _json(o, status: 401, data: {'code': 401, 'message': 'unauthorized'}),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);
    });

    test('账户接口 code=0 但取不到用户信息 → 过期', () async {
      final service = _serviceWith((o) => _json(o, data: {'code': 0}));
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);
    });

    test('网络不通 → 保持已连接，不误导用户换 Cookie', () async {
      final service = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio((o) => throw DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
              error: 'no network',
            )),
      );
      await initSettled(service);
      // 断网不是 Cookie 的错：把断网报成 Cookie 失效会让用户反复重贴
      expect(service.authStatus, AuthStatus.authenticated);
    });

    test('未知服务端故障（5xx 非 JSON）→ 不判为登录失效', () async {
      final service = _serviceWith(
        (o) => Response<dynamic>(
          requestOptions: o,
          statusCode: 500,
          data: '<html>Internal Server Error</html>',
        ),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.authenticated);
    });
  });

  group('取直链失败的登录态识别', () {
    /// 先让 init 校验通过（拿到 authenticated），再模拟取直链失败。
    Future<QuarkDriveService> authedService(
      Response<dynamic> Function(RequestOptions options) onDownload,
    ) async {
      final service = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio((o) {
          if (o.path.contains('/account/info')) return _accountOk(o);
          return onDownload(o);
        }),
      );
      await initSettled(service);
      return service;
    }

    test('CDN 返回 412 且响应体非 JSON → 过期（原先完全漏掉）', () async {
      final service = await authedService(
        (o) => Response<dynamic>(
          requestOptions: o,
          statusCode: 412,
          data: 'precondition failed',
        ),
      );
      expect(service.authStatus, AuthStatus.authenticated);
      await expectLater(service.getAudioStreamUrl('fid'), throwsA(isA<Exception>()));
      // 修复前：非 JSON 分支直接 throw，根本走不到登录态判定，UI 一直显示已连接
      expect(service.authStatus, AuthStatus.expired);
    });

    test('取直链返回登录失效业务码 → 过期', () async {
      final service = await authedService(
        (o) => _json(o, data: {'code': 40001, 'message': '登录态失效'}),
      );
      await expectLater(service.getAudioStreamUrl('fid'), throwsA(isA<Exception>()));
      expect(service.authStatus, AuthStatus.expired);
    });

    test('取直链成功 → 保持已连接', () async {
      final service = await authedService(
        (o) => _json(
          o,
          data: {
            'code': 0,
            'data': [
              {'download_url': 'https://cdn.example.com/a.mp3'},
            ],
          },
        ),
      );
      final stream = await service.getAudioStreamUrl('fid');
      expect(stream.url, 'https://cdn.example.com/a.mp3');
      expect(service.authStatus, AuthStatus.authenticated);
    });

    test('5xx 服务端故障不算登录失效', () async {
      final service = await authedService(
        (o) => Response<dynamic>(
          requestOptions: o,
          statusCode: 502,
          data: '<html>bad gateway</html>',
        ),
      );
      await expectLater(service.getAudioStreamUrl('fid'), throwsA(isA<Exception>()));
      expect(service.authStatus, AuthStatus.authenticated);
    });
  });

  group('重连流程', () {
    test('冷启动判定过期后，重贴无效的 Cookie 不会被回滚成已连接', () async {
      final service = QuarkDriveService(
        _FakeStorage('dead-cookie'),
        dio: _fakeDio((o) => Response<dynamic>(
              requestOptions: o,
              statusCode: 200,
              data: '<html>请重新登录</html>',
            )),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);

      await expectLater(
        service.setCookie('another-bad-cookie'),
        throwsA(isA<Exception>()),
      );
      // 修复前按「本地有没有 Cookie 字符串」回滚，会把刚判定的过期又改回已连接
      expect(service.authStatus, AuthStatus.expired);
    });

    test('重贴有效的 Cookie → 恢复已连接', () async {
      var good = false;
      final service = QuarkDriveService(
        _FakeStorage('dead-cookie'),
        dio: _fakeDio((o) {
          if (good) return _accountOk(o);
          return Response<dynamic>(
            requestOptions: o,
            statusCode: 200,
            data: '<html>请重新登录</html>',
          );
        }),
      );
      await initSettled(service);
      expect(service.authStatus, AuthStatus.expired);

      good = true;
      await service.setCookie('fresh-cookie');
      expect(service.authStatus, AuthStatus.authenticated);
    });
  });

  group('日志安全', () {
    test('非 JSON 的异常信息里不带响应体原文', () async {
      final service = await (() async {
        final s = QuarkDriveService(
          _FakeStorage('test-cookie'),
          dio: _fakeDio((o) {
            if (o.path.contains('/account/info')) return _accountOk(o);
            return Response<dynamic>(
              requestOptions: o,
              statusCode: 412,
              data: '<html>secret-token-abc123</html>',
            );
          }),
        );
        await initSettled(s);
        return s;
      })();

      Object? caught;
      try {
        await service.getAudioStreamUrl('fid');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<Exception>());
      // Cookie / 响应体原文不能进日志：只保留类型与长度
      expect(caught.toString(), isNot(contains('secret-token-abc123')));
      expect(caught.toString(), contains('响应非 JSON'));
    });
  });
}
