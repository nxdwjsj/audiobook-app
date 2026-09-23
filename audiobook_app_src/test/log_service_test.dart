import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/log_service.dart';

/// SEC-04：日志脱敏与崩溃回捞（crash.log 轮转 / 导出）。
void main() {
  group('URL 与密钥脱敏', () {
    test('download_url 的时效签名被脱敏，host/path 保留', () {
      const raw = '解析到流地址: '
          'https://dl-pc-sz.pds.quark.cn/dlink/abc?Expires=1799999999'
          '&Signature=SECRETSIG%3D&x-oss-expires=1799999999';

      final safe = LogService.sanitize(raw);

      // 敏感的签名值不能出现
      expect(safe, isNot(contains('SECRETSIG')));
      expect(safe, isNot(contains('1799999999')));
      // 便于排查的信息要保留
      expect(safe, contains('dl-pc-sz.pds.quark.cn'));
      expect(safe, contains('/dlink/abc'));
      expect(safe, contains('Expires=<redacted>'));
      expect(safe, contains('Signature=<redacted>'));
      expect(safe, contains('x-oss-expires=<redacted>'));
    });

    test('stoken / access_token 之类的查询参数同样被脱敏', () {
      final safe = LogService.sanitize(
        'GET https://drive-pc.quark.cn/1/clouddrive/share/detail'
        '?pwd_id=abc&stoken=STOKENVALUE&ver=2',
      );
      expect(safe, isNot(contains('STOKENVALUE')));
      expect(safe, contains('stoken=<redacted>'));
      // 非敏感的 key 本身保留，只是值被打码
      expect(safe, contains('pwd_id=<redacted>'));
      expect(safe, contains('https://drive-pc.quark.cn/1/clouddrive/share/detail'));
    });

    test('Cookie / Authorization 键值一律打码', () {
      final safe = LogService.sanitize(
        'headers: Cookie=BDUSS=abcdef123456; __puus=xyz; '
        'Authorization: Bearer TOKENVALUE',
      );
      expect(safe, isNot(contains('abcdef123456')));
      expect(safe, isNot(contains('TOKENVALUE')));
      expect(safe, contains('<redacted>'));
    });

    test('非 URL 的普通文本原样保留', () {
      const raw = '加载章节 3/120: 第 3 集';
      expect(LogService.sanitize(raw), raw);
    });

    test('redactUrl 对非 URL 输入返回占位符', () {
      expect(LogService.redactUrl('not-a-url'), '<redacted-url>');
    });

    test('URL 的 fragment（可能带 token）不保留', () {
      final safe = LogService.sanitize('https://pan.quark.cn/s/xyz#token=ABC');
      expect(safe, isNot(contains('ABC')));
      expect(safe, contains('https://pan.quark.cn/s/xyz'));
    });
  });

  group('崩溃记录与轮转', () {
    late Directory tmp;
    late LogService log;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lingyun_log_test');
      log = LogService(directoryProvider: () async => tmp);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('recordCrash 落盘 crash.log，且报告里不含敏感串', () async {
      final file = await log.recordCrash(
        Exception('drive error: https://cdn.x.com/a.mp3?Signature=RAW_SIG'),
        StackTrace.current,
      );

      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      expect(file.path, endsWith(LogService.logFileName));

      final content = await file.readAsString();
      expect(content, contains('drive error'));
      expect(content, isNot(contains('RAW_SIG')));
      expect(content, contains('Signature=<redacted>'));
    });

    test('崩溃报告附带最近的 info 日志作为现场上下文', () async {
      log.info('进入播放页');
      log.info('解析直链 https://cdn.x.com/a.mp3?Signature=LEAK');
      final file = await log.recordCrash(Exception('boom'), null);

      final content = await file!.readAsString();
      expect(content, contains('进入播放页'));
      expect(content, contains('最近日志'));
      // 上下文里的敏感 URL 也必须已脱敏
      expect(content, isNot(contains('LEAK')));
      expect(log.recentLogs, hasLength(2));
    });

    test('轮转：连续 4 次崩溃后最多保留 3 个文件，最老的被丢弃', () async {
      for (var i = 1; i <= 4; i++) {
        await log.recordCrash(Exception('boom-$i'), null);
      }

      final files = await log.logFiles();
      expect(files, hasLength(LogService.maxFiles));

      final all = await log.readAll();
      // 第 4 次已把第 1 次挤出去
      expect(all, isNot(contains('boom-1')));
      expect(all, contains('boom-2'));
      expect(all, contains('boom-3'));
      expect(all, contains('boom-4'));
    });

    test('readAll 在没有任何日志时返回空串', () async {
      expect((await log.readAll()).trim(), isEmpty);
    });

    test('exportToFile 生成带时间戳的导出文件', () async {
      await log.recordCrash(Exception('boom'), null);
      final exported = await log.exportToFile();

      expect(exported, isNotNull);
      expect(exported!.existsSync(), isTrue);
      expect(exported.path, contains('lingyun_log_'));
      expect(await exported.readAsString(), contains('boom'));
    });

    test('无日志时不产出空的导出文件', () async {
      expect(await log.exportToFile(), isNull);
    });

    test('clear 清空文件与内存缓冲', () async {
      log.info('hello');
      await log.recordCrash(Exception('boom'), null);
      expect((await log.logFiles()), isNotEmpty);

      await log.clear();

      expect(await log.logFiles(), isEmpty);
      expect(log.recentLogs, isEmpty);
    });
  });
}
