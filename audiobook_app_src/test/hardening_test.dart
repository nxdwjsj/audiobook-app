import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/baidu_drive_service.dart';
import 'package:audiobook_app/services/cloud_drive_service.dart';
import 'package:audiobook_app/services/drive_list_cache.dart';
import 'package:audiobook_app/services/http/network_client.dart';
import 'package:audiobook_app/services/log_service.dart';
import 'package:audiobook_app/services/quark_drive_service.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 三项加固的回归护栏（由 team-lead 在主理人复核阶段补）：
///
/// 1. **日志脱敏的 JSON 形态**：早先的正则要求键名后**直接**是 `:` 或 `=`，
///    而 JSON 里键名后面紧跟的是闭合引号，于是 `{"stoken":"xxx"}` 这类形态
///    全部漏过、原样落进日志。已修，这里锁住行为。
/// 2. **HTTP 412 但响应体 `code=0`**：既不是非 JSON、业务码又是 0，
///    只看这两条会被当成成功响应放过去，登录态始终不被标记。
/// 3. **目录缓存的账号隔离下沉到 service**：清缓存原本写在各个调用页面，
///    漏一处新账号就会在 60 秒 TTL 内看到上一个账号的目录。
///
/// 全部走 dio 拦截器伪造响应，不依赖真实网络。

class _FakeQuarkStorage extends StorageService {
  _FakeQuarkStorage();

  String cookie = 'test-cookie';
  String? saved;

  @override
  String? getQuarkCookie() => cookie.isEmpty ? null : cookie;

  @override
  Future<void> saveQuarkCookie(String value) async => saved = value;
}

class _FakeBaiduStorage extends StorageService {
  String? token;
  String? cookie;
  String? savedToken;
  String? savedCookie;

  @override
  String? getBaiduToken() => token;

  @override
  String? getBaiduCookie() => cookie;

  @override
  String? getBaiduAppKey() => null;

  @override
  Future<void> saveBaiduToken(String value) async => savedToken = value;

  @override
  Future<void> saveBaiduCookie(String value) async => savedCookie = value;

  @override
  Future<void> saveBaiduAppKey(String value) async {}
}

Dio _fakeDio(Response<dynamic> Function(RequestOptions options) respond) {
  final dio = createNetworkClient();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(respond(options)),
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

void main() {
  group('日志脱敏：JSON 形态不得泄漏', () {
    const secret = 'SECRETVALUE123';

    void expectRedacted(String input, {String? label}) {
      final out = LogService.sanitize(input);
      expect(out.contains(secret), isFalse,
          reason: '${label ?? input} 的值泄漏了：$out');
      expect(out.contains('<redacted>'), isTrue,
          reason: '${label ?? input} 未被打码：$out');
    }

    test('双引号 JSON（无空格）', () {
      expectRedacted('{"stoken":"$secret"}');
    });

    test('双引号 JSON（冒号后有空格）', () {
      expectRedacted('{"stoken": "$secret"}');
    });

    test('单引号形态', () {
      expectRedacted("{'stoken':'$secret'}");
    });

    test('嵌套 JSON 体内的敏感键', () {
      expectRedacted('body={"data":{"access_token":"$secret"}}');
    });

    test('键名大小写变体', () {
      expectRedacted('{"Stoken":"$secret"}');
      expectRedacted('{"AUTHORIZATION":"$secret"}');
    });

    test('多条敏感键同时出现都要打码', () {
      final out = LogService.sanitize(
        '{"bduss":"$secret","stoken":"${secret}2","cookie":"x"}',
      );
      expect(out.contains(secret), isFalse, reason: out);
      expect(out.contains('${secret}2'), isFalse, reason: out);
    });

    test('回归：原有非 JSON 形态仍要打码', () {
      expectRedacted('stoken=$secret');
      expectRedacted('Cookie=$secret');
      expectRedacted('Authorization: Bearer $secret');
      expectRedacted('Authorization: Basic $secret');
      expectRedacted('https://x.com/a?stoken=$secret&b=1');
    });

    test('不过度脱敏：非敏感键的值必须原样保留', () {
      final out = LogService.sanitize('{"title":"hello world","n":3}');
      expect(out.contains('hello world'), isTrue, reason: out);
      expect(out.contains('3'), isTrue, reason: out);
    });

    test('脱敏后 JSON 仍是合法形态（引号/分隔符不被吃掉）', () {
      final out = LogService.sanitize('{"stoken":"$secret"}');
      expect(out, '{"stoken":"<redacted>"}');
    });
  });

  group('夸克响应判定：HTTP 412 + code=0 也要判为需要重连', () {
    test('412 且响应体 code=0 → 标记 expired 而不是当成成功', () async {
      final service = QuarkDriveService(
        _FakeQuarkStorage(),
        dio: _fakeDio((options) => _json(
              options,
              status: 412,
              data: {'code': 0, 'message': 'ok'},
            )),
      );
      await service.init();

      await expectLater(
        service.getAudioStreamUrl('fid-1'),
        throwsA(isA<Exception>()),
      );
      expect(service.authStatus, AuthStatus.expired,
          reason: '412 但 body code=0 被漏判，登录态没被标记');
    });

    test('对照：200 且返回有效直链时不得误判为失效', () async {
      final service = QuarkDriveService(
        _FakeQuarkStorage(),
        dio: _fakeDio((options) => _json(
              options,
              status: 200,
              data: {
                'code': 0,
                'data': [
                  {'download_url': 'https://cdn.example.com/a.mp3'},
                ],
              },
            )),
      );
      await service.init();

      final stream = await service.getAudioStreamUrl('fid-1');
      expect(stream.url, contains('cdn.example.com'));
      expect(service.authStatus, AuthStatus.authenticated);
    });
  });

  group('目录缓存账号隔离：清缓存必须发生在 service 内部', () {
    setUp(() => DriveListCache.instance.clear());
    tearDown(() => DriveListCache.instance.clear());

    void seedCache() {
      DriveListCache.instance.put('quark|fid|/', const []);
      expect(DriveListCache.instance.length, 1);
    }

    test('夸克 setCookie（成功换账号）后缓存被清空', () async {
      final service = QuarkDriveService(
        _FakeQuarkStorage(),
        dio: _fakeDio((options) => _json(
              options,
              status: 200,
              data: {
                'code': 0,
                'data': {'nickname': 'someone'},
              },
            )),
      );
      seedCache();
      await service.setCookie('another-account-cookie');
      expect(DriveListCache.instance.length, 0,
          reason: '换账号后旧目录缓存仍在，会串到上一个账号的目录');
    });

    test('夸克清空 Cookie（等同解绑账号）后缓存被清空', () async {
      final service = QuarkDriveService(
        _FakeQuarkStorage(),
        dio: _fakeDio((options) => _json(options, data: {'code': 0})),
      );
      seedCache();
      await service.setCookie('');
      expect(DriveListCache.instance.length, 0);
    });

    test('夸克 logout 后缓存被清空', () async {
      final service = QuarkDriveService(
        _FakeQuarkStorage(),
        dio: _fakeDio((options) => _json(options, data: {'code': 0})),
      );
      seedCache();
      await service.logout();
      expect(DriveListCache.instance.length, 0);
    });

    test('百度 logout 后缓存被清空', () async {
      final service = BaiduDriveService(
        _FakeBaiduStorage(),
        dio: _fakeDio((options) => _json(options, data: {'errno': 0})),
      );
      seedCache();
      await service.logout();
      expect(DriveListCache.instance.length, 0);
    });

    test('百度清空 Cookie 后缓存被清空', () async {
      final service = BaiduDriveService(
        _FakeBaiduStorage(),
        dio: _fakeDio((options) => _json(options, data: {'errno': 0})),
      );
      seedCache();
      await service.setCookie('');
      expect(DriveListCache.instance.length, 0);
    });
  });
}
