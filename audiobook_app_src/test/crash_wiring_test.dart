import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/main.dart';
import 'package:audiobook_app/services/log_service.dart';

/// 验证「崩溃出口 → LogService」真的接通了。
///
/// `lib/main.dart` 里的 [reportError] 是四个崩溃来源的唯一漏斗
/// （`FlutterError.onError` / `PlatformDispatcher.instance.onError` /
/// `runZonedGuarded` 的 onError / 存储初始化重试）。这里直接调用它，
/// 断言异常正文确实落盘到 `crash.log`——只测漏斗，不需要真触发一次崩溃。
void main() {
  group('崩溃出口接线（main.reportError → LogService.recordCrash）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lingyun_crash_wire_');
      LogService.instance.directoryProvider = () async => tmp;
    });

    tearDown(() async {
      await LogService.instance.clear();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('reportError 把异常正文与 tag 落盘到 crash.log', () async {
      reportError(
        StateError('接线探针-boom-42'),
        StackTrace.current,
        tag: 'WireTest',
      );

      // reportError 内部是 fire-and-forget（unawaited），轮询等它刷盘。
      File? crash;
      for (var i = 0; i < 100; i++) {
        final files = await LogService.instance.logFiles();
        if (files.isNotEmpty) {
          crash = files.first;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(crash, isNotNull, reason: 'reportError 必须把崩溃写入 crash.log');
      final text = await crash!.readAsString();
      expect(text, contains('接线探针-boom-42'));
      expect(text, contains('WireTest'), reason: 'tag 应透传到落盘内容');
    });

    test('落盘失败时 reportError 绝不抛出（不把日志问题带崩主流程）', () {
      LogService.instance.directoryProvider =
          () => throw const FileSystemException('目录不可写');
      expect(
        () => reportError(StateError('x'), StackTrace.current, tag: 'WireTest'),
        returnsNormally,
      );
    });
  });
}
