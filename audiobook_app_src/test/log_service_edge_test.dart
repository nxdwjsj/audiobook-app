import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/log_service.dart';

/// SEC-04 脱敏的**攻击性**补充用例（QA 加码）。
///
/// 工程师自述第一版把 `Authorization: Bearer TOKEN` 只打码到 `Bearer`、
/// 漏了真 token，后来才修。这里专门攻击大小写、多段空格、Basic、URL 编码、
/// 分号分隔等变体，确认都不漏。
void main() {
  group('脱敏——Bearer / Basic 与变体', () {
    test('Bearer 多段空格也不漏 token', () {
      final safe = LogService.sanitize('Authorization: Bearer   MULTISPACE_TOKEN');
      expect(safe, isNot(contains('MULTISPACE_TOKEN')));
      expect(safe, contains('<redacted>'));
    });

    test('小写 authorization:bearer（无空格）也不漏', () {
      final safe = LogService.sanitize('authorization:bearer lowercase_TOKEN');
      expect(safe, isNot(contains('lowercase_TOKEN')));
    });

    test('Basic 认证同样整体打码（不得只留 Basic）', () {
      final safe = LogService.sanitize('Authorization: Basic dXNlcjpwYXNzd29yZA==');
      expect(safe, isNot(contains('dXNlcjpwYXNzd29yZA==')));
      expect(safe, contains('<redacted>'));
    });

    test('等号形态（Authorization=Bearer tok）也被吃掉', () {
      final safe = LogService.sanitize('Authorization=Bearer EQSTYLE_TOKEN');
      expect(safe, isNot(contains('EQSTYLE_TOKEN')));
    });
  });

  group('脱敏——Cookie / stoken / bduss 变体', () {
    test('Set-Cookie 分号分隔，会话值不残留', () {
      final safe = LogService.sanitize(
        'Set-Cookie: __puus=SESSIONVAL123; Path=/; HttpOnly',
      );
      expect(safe, isNot(contains('SESSIONVAL123')));
    });

    test('小写 bduss / access-token 也命中', () {
      final a = LogService.sanitize('bduss=LOWBDUSSVALUE');
      final b = LogService.sanitize('access-token: ACCESSTOKENVAL');
      expect(a, isNot(contains('LOWBDUSSVALUE')));
      expect(b, isNot(contains('ACCESSTOKENVAL')));
    });

    test('stoken 出现在普通文本（非 URL）里也打码', () {
      final safe = LogService.sanitize('保存分享令牌 stoken=RAWSTOKEN 成功');
      expect(safe, isNot(contains('RAWSTOKEN')));
      expect(safe, contains('stoken=<redacted>'));
    });
  });

  group('脱敏——URL 与 URL 编码', () {
    test('URL 编码过的签名值也整体打码', () {
      final safe = LogService.sanitize(
        'https://cdn.x.com/a.mp3?Signature=SEC%3DRET%3D&Expires=999888777',
      );
      expect(safe, isNot(contains('SEC')));
      expect(safe, isNot(contains('999888777')));
      expect(safe, contains('Signature=<redacted>'));
      expect(safe, contains('Expires=<redacted>'));
      expect(safe, contains('https://cdn.x.com/a.mp3'));
    });

    test('URL 中带 access_token 查询参数不漏', () {
      final safe = LogService.sanitize('https://x.com/p?access_token=ATLEAK&ver=2');
      expect(safe, isNot(contains('ATLEAK')));
    });

    test('reportCrash 内嵌 URL 的签名值不落盘', () async {
      final tmp = await Directory.systemTemp.createTemp('lingyun_log_edge');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final log = LogService(directoryProvider: () async => tmp);
      final file = await log.recordCrash(
        Exception(
          'boom https://dl-pc-sz.pds.quark.cn/x?x-oss-expires=555111&Signature=EDGELEAK',
        ),
        null,
      );
      final text = await file!.readAsString();
      expect(text, isNot(contains('EDGELEAK')));
      expect(text, isNot(contains('555111')));
      expect(text, contains('x-oss-expires=<redacted>'));
    });
  });

  group('recordCrash 永不抛出', () {
    test('目录 provider 抛异常时返回 null 且不抛', () async {
      final log = LogService(
        directoryProvider: () => throw const FileSystemException('目录不可写'),
      );
      await expectLater(log.recordCrash(Exception('x'), null), completes);
      expect(await log.recordCrash(Exception('x'), null), isNull);
    });

    test('目录路径被同名文件占用（无法建目录）时返回 null 且不抛', () async {
      final tmp = await Directory.systemTemp.createTemp('lingyun_log_block');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      // 造一个文件，再把它的路径当作目录交给 LogService → create() 必失败
      final blocker = File('${tmp.path}/blocked');
      await blocker.writeAsString('x');
      final log = LogService(directoryProvider: () async => Directory(blocker.path));

      final result = await log.recordCrash(Exception('boom'), null);
      expect(result, isNull, reason: '写不进去必须返回 null，而不是把主流程带崩');
    });
  });

  group('轮转顺序（3 文件）', () {
    late Directory tmp;
    late LogService log;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lingyun_log_rot');
      log = LogService(directoryProvider: () async => tmp);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('连续 5 次：crash.log 最新、依次滚到 .1/.2，最老被丢', () async {
      for (var i = 1; i <= 5; i++) {
        await log.recordCrash(Exception('boom-$i'), null);
      }
      final files = await log.logFiles();
      expect(files, hasLength(LogService.maxFiles));

      final newest = await File('${tmp.path}/crash.log').readAsString();
      final second = await File('${tmp.path}/crash.1.log').readAsString();
      final third = await File('${tmp.path}/crash.2.log').readAsString();

      expect(newest, contains('boom-5'));
      expect(second, contains('boom-4'));
      expect(third, contains('boom-3'));
      expect(newest, isNot(contains('boom-1')));
      expect(third, isNot(contains('boom-1')));
    });
  });
}
