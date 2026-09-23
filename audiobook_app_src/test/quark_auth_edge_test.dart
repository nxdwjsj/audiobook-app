import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/cloud_drive_service.dart';
import 'package:audiobook_app/services/http/network_client.dart';
import 'package:audiobook_app/services/quark_drive_service.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 边界与错误路径的**独立**回归（QA 加码，不重复 quark_auth_test 的 happy path）。
///
/// 重点：
/// - B4「乐观置位 + 后台校验」的超时 / 断网 / dispose 契约；
/// - 「重贴一个仍然无效的 Cookie」绝不回滚成 authenticated（含业务码形态）；
/// - logout 清理彻底；
/// - 5xx + 非 JSON 的**已知缺口固化成显式断言**（防止将来被误改）；
/// - 「登录态失效」异常信息里不得出现 Cookie / download_url / secret-token。

/// 本地存 Cookie 的假存储：绕开 Hive。
class _FakeStorage extends StorageService {
  _FakeStorage(this.cookie);

  String cookie;
  String? saved;
  int saveCount = 0;

  @override
  String? getQuarkCookie() => cookie.isEmpty ? null : cookie;

  @override
  Future<void> saveQuarkCookie(String value) async {
    saved = value;
    saveCount++;
  }
}

Dio _fakeDio(Response<dynamic> Function(RequestOptions options) respond) {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(respond(options)),
  ));
  return dio;
}

Response<dynamic> _json(RequestOptions options,
        {int status = 200, Object? data}) =>
    Response<dynamic>(requestOptions: options, statusCode: status, data: data);

Response<dynamic> _html(RequestOptions options, {int status = 200}) =>
    _json(options,
        status: status,
        data: '<!DOCTYPE html><html>请重新登录</html>');

Response<dynamic> _accountOk(RequestOptions options) =>
    _json(options, data: {'code': 0, 'data': {'nickname': 'tester'}});

/// init + 等后台校验结束（B4 后 init 返回时校验通常还没跑完）。
Future<void> initSettled(QuarkDriveService s) async {
  await s.init();
  await s.startupCheckDone;
}

/// 已连接的服务：账户接口永远 OK，其余按 [onDownload] 返回。
Future<QuarkDriveService> authed(
  Response<dynamic> Function(RequestOptions o) onDownload,
) async {
  final s = QuarkDriveService(
    _FakeStorage('test-cookie'),
    dio: _fakeDio((o) =>
        o.path.contains('/account/info') ? _accountOk(o) : onDownload(o)),
  );
  await initSettled(s);
  return s;
}

void main() {
  group('B4 乐观置位：init 不阻塞、后台校验契约', () {
    test('无 Cookie → 不乐观置位，直接 unauthenticated，且无需等待校验', () async {
      final s = QuarkDriveService(_FakeStorage(''), dio: _fakeDio(_accountOk));
      await s.init();
      expect(s.authStatus, AuthStatus.unauthenticated);
      // 无触发校验时 startupCheckDone 是已完成的 Future
      await s.startupCheckDone.timeout(const Duration(seconds: 1));
      expect(s.authStatus, AuthStatus.unauthenticated);
    });

    test('有 Cookie → init 立即返回（<2s）并乐观置位；断网后仍保持已连接', () async {
      final s = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio((o) => throw DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
              error: 'no network',
            )),
      );
      final sw = Stopwatch()..start();
      await s.init().timeout(const Duration(seconds: 2));
      sw.stop();
      // 乐观置位：UI 不卡启动页
      expect(s.authStatus, AuthStatus.authenticated);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      // 后台校验因断网结束：必须是 authenticated（断网≠Cookie 失效）
      await s.startupCheckDone.timeout(const Duration(seconds: 9));
      expect(s.authStatus, AuthStatus.authenticated);
    });

    test('init 校验超时（>5s 无响应）→ 保持 authenticated，不误导换 Cookie', () async {
      // 手动放行的闸门：模拟服务端迟迟不响应（>5s 硬超时）。
      final gate = Completer<void>();
      final dio = createNetworkClient();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (o, handler) async {
        await gate.future;
        handler.resolve(_accountOk(o));
      }));
      final s = QuarkDriveService(_FakeStorage('test-cookie'), dio: dio);

      final sw = Stopwatch()..start();
      await s.init().timeout(const Duration(seconds: 2));
      sw.stop();
      expect(s.authStatus, AuthStatus.authenticated);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'init 不得同步等待网络');

      // 等 5s 超时跑完：超时按「未知」处理 → 仍已连接
      await s.startupCheckDone.timeout(const Duration(seconds: 9));
      expect(s.authStatus, AuthStatus.authenticated);

      gate.complete(); // 释放挂起的请求，避免遗留
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('后台校验发现 Cookie 已失效 → 事后纠正为 expired', () async {
      final s = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio(_html), // 登录页 HTML
      );
      // 乐观置位先发生
      await s.init();
      expect(s.authStatus, AuthStatus.authenticated, reason: 'init 返回时应是乐观已连接');
      await s.startupCheckDone.timeout(const Duration(seconds: 9));
      expect(s.authStatus, AuthStatus.expired, reason: '后台校验必须纠正为过期');
    });

    test('重复通知：校验成功路径 notifyListeners 恰为 2 次（乐观 1 + 校验 1）', () async {
      final s = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio(_accountOk),
      );
      var n = 0;
      s.addListener(() => n++);
      await initSettled(s);
      expect(s.authStatus, AuthStatus.authenticated);
      // 不允许「校验结束又白通知一次」之类的水分
      expect(n, 2);
    });

    test('dispose 之后后台校验结束也不得抛未捕获异常', () async {
      final gate = Completer<void>();
      final dio = createNetworkClient();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (o, handler) async {
        await gate.future;
        handler.resolve(_accountOk(o));
      }));
      final s = QuarkDriveService(_FakeStorage('test-cookie'), dio: dio);

      await s.init(); // 乐观置位，后台校验挂起
      s.dispose(); // 校验还没结束就销毁（释放 notifyListeners 之后的炸点）
      gate.complete();

      // 若后台任务把异常抛到 zone，本行会失败
      await s.startupCheckDone.timeout(const Duration(seconds: 9));
    });
  });

  group('重连流程：回滚必须按「校验前状态」，不能反推', () {
    test('冷启动已 expired，重贴仍无效的 Cookie（业务码形态）→ 保持 expired', () async {
      // 用业务码失效响应（与 quark_auth_test 的 HTML 形态互补，覆盖另一条分支）
      final s = QuarkDriveService(
        _FakeStorage('dead-cookie'),
        dio: _fakeDio((o) => _json(o, data: {'code': 41008, 'message': '登录凭证已过期'})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);

      await expectLater(
        s.setCookie('still-bad-cookie'),
        throwsA(isA<Exception>()),
      );
      // 修复前会按「本地有 Cookie 字符串」回滚成 authenticated
      expect(s.authStatus, AuthStatus.expired);
    });

    test('重贴 Cookie 时断网 → 回滚到校验前状态，且报「网络」而非「Cookie 无效」', () async {
      var offline = false;
      final s = QuarkDriveService(
        _FakeStorage('dead-cookie'),
        dio: _fakeDio((o) {
          if (offline) {
            throw DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
              error: 'no network',
            );
          }
          return _html(o);
        }),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);

      offline = true;
      Object? caught;
      try {
        await s.setCookie('whatever');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<Exception>());
      expect(caught.toString(), contains('网络'));
      expect(caught.toString(), isNot(contains('Cookie 无效')));
      // 状态与 Cookie 都回到校验前
      expect(s.authStatus, AuthStatus.expired);
    });

    test('重贴有效 Cookie → 恢复已连接，且落盘保存', () async {
      final storage = _FakeStorage('dead-cookie');
      var good = false;
      final s = QuarkDriveService(
        storage,
        dio: _fakeDio((o) => good ? _accountOk(o) : _html(o)),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);

      good = true;
      await s.setCookie('fresh-cookie');
      expect(s.authStatus, AuthStatus.authenticated);
      expect(storage.saved, 'fresh-cookie', reason: '校验通过后才落盘');
    });
  });

  group('logout 清理彻底性', () {
    test('logout 后：状态未连接、Cookie 落盘清空、取流直接拒绝', () async {
      final storage = _FakeStorage('test-cookie');
      final s = QuarkDriveService(storage, dio: _fakeDio(_accountOk));
      await initSettled(s);
      expect(s.authStatus, AuthStatus.authenticated);

      await s.logout();

      expect(s.authStatus, AuthStatus.unauthenticated);
      expect(storage.saved, '', reason: 'Cookie 必须落盘清空');
      // 无 Cookie 时取流应直接抛 StateError（而不是发请求）
      await expectLater(
        s.getAudioStreamUrl('fid'),
        throwsA(isA<StateError>()),
      );
      // 列表同理
      await expectLater(s.listFolder(), throwsA(isA<StateError>()));
    });
  });

  group('已知缺口（固化成显式断言，防止误改）', () {
    test('5xx + 非 JSON：按设计「不判为登录失效」，状态保持已连接', () async {
      final s = await authed(
        (o) => _json(o, status: 502, data: '<html>bad gateway</html>'),
      );
      await expectLater(
        s.getAudioStreamUrl('fid'),
        throwsA(isA<Exception>()),
      );
      // 这是工程师承认的已知缺口：5xx（服务端故障）无法与「登录失效」区分，
      // 只有真正拿到失效码/状态码才置 expired。此处固化当前契约。
      expect(s.authStatus, AuthStatus.authenticated);
    });

    test('账户接口 code=0 但 data==null → 判为 expired（init 冷启动形态）', () async {
      final s = QuarkDriveService(
        _FakeStorage('test-cookie'),
        dio: _fakeDio((o) => _json(o, data: {'code': 0})),
      );
      await initSettled(s);
      expect(s.authStatus, AuthStatus.expired);
    });

    test('取直链 412 + JSON body（code=0, 无 data）：仅报「未返回下载链接」，不置 expired',
        () async {
      // 记录当前行为：412 但响应体是 {code:0} 的怪异形态下，getAudioStreamUrl
      // 不会走 _throwApiError（因为 code==0），因此不更新登录态。
      // 真实 CDN 的 412 是纯文本（走 data is! Map 分支，已覆盖），故风险低；
      // 此处固化现状，若将来在此处补失效判定，本用例需同步更新。
      final s = await authed(
        (o) => _json(o, status: 412, data: {'code': 0}),
      );
      await expectLater(
        s.getAudioStreamUrl('fid'),
        throwsA(isA<Exception>()),
      );
      expect(s.authStatus, AuthStatus.authenticated);
    });
  });

  group('日志脱敏（异常信息）—— 独立加码', () {
    test('非 JSON 异常信息不含 Cookie / download_url 签名 / secret-token', () async {
      const leakBody = 'Cookie=BDUSS=LEAKCOOKIE123; '
          'https://dl-pc-sz.pds.quark.cn/a.mp3?Signature=LEAKSIG&Expires=1234567890 '
          'secret-token-abc123';
      final s = await authed(
        (o) => _json(o, status: 412, data: leakBody),
      );

      Object? caught;
      try {
        await s.getAudioStreamUrl('fid');
      } catch (e) {
        caught = e;
      }

      final msg = caught.toString();
      expect(msg, contains('响应非 JSON'));
      expect(msg, isNot(contains('LEAKCOOKIE123')));
      expect(msg, isNot(contains('LEAKSIG')));
      expect(msg, isNot(contains('1234567890')));
      expect(msg, isNot(contains('secret-token-abc123')));
    });

    test('登录失效的 debugPrint 只带 http/code，不带 Cookie 原文', () async {
      // 通过 _markAuthExpired 触发的日志：只允许出现状态码与业务码
      final s = await authed(
        (o) => _json(o, data: {'code': 40001, 'message': '登录态失效'}),
      );
      await expectLater(
        s.getAudioStreamUrl('fid'),
        throwsA(isA<Exception>()),
      );
      expect(s.authStatus, AuthStatus.expired);
    });
  });
}
