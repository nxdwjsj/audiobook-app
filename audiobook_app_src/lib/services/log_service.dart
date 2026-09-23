import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 统一日志与崩溃回捞服务（SEC-04）。
///
/// 解决三件事：
/// 1. **release 不泄漏业务细节**：info / warn 级别的日志在 release 包直接丢弃，
///    避免把网盘直链、Cookie 之类的上下文打进 logcat；
/// 2. **URL 脱敏**：`file/download` 返回的 `download_url` 带时效签名，另有
///    `stoken`、`access_token` 等，落盘或打印前一律打码（保留 host / path /
///    参数名，方便排查）；
/// 3. **崩溃可回捞**：崩溃写应用私有目录的 `crash.log`，最多保留 3 个文件
///    轮转，附带最近若干条 info 日志作为现场上下文，并提供导出入口。
///
/// 注意：本类只负责「生成可导出的日志文件」。真正的「分享/发送」需要系统
/// 分享或文件选择器，本期不引入新依赖，[exportToFile] 先把文件准备好。
class LogService {
  LogService({Future<Directory> Function()? directoryProvider})
      : directoryProvider = directoryProvider ?? _defaultDirectory;

  /// 全局实例。App 运行时用它；测试自行 new 一个并注入临时目录。
  static final LogService instance = LogService();

  /// 崩溃日志文件名。
  static const String logFileName = 'crash.log';

  /// 轮转保留的文件数：crash.log / crash.1.log / crash.2.log。
  static const int maxFiles = 3;

  /// 崩溃报告中附带的最近日志条数上限。
  static const int recentLogLimit = 100;

  /// 崩溃日志落盘目录。默认应用私有目录；测试可注入临时目录。
  Future<Directory> Function() directoryProvider;

  static Future<Directory> _defaultDirectory() =>
      getApplicationDocumentsDirectory();

  /// 最近 info/warn 日志（环形缓冲），崩溃时一并落盘作为现场上下文。
  final List<String> _recent = <String>[];

  /// 最近日志的只读快照（测试与排查用）。
  List<String> get recentLogs => List<String>.unmodifiable(_recent);

  // ------------------------------------------------------------------
  // 日志
  // ------------------------------------------------------------------

  /// 一般信息。release 包**直接丢弃**，不落 logcat。
  void info(String message) {
    if (kReleaseMode) return;
    _write('INFO', message);
  }

  /// 警告。与 [info] 一样受 release 静默约束。
  void warn(String message) {
    if (kReleaseMode) return;
    _write('WARN', message);
  }

  /// 错误。release 也会输出，但仍经过脱敏。
  void error(String message, [Object? cause]) {
    _write('ERROR', cause == null ? message : '$message | $cause');
  }

  void _write(String level, String message) {
    final safe = sanitize(message);
    final line = '[${DateTime.now().toIso8601String()}][$level] $safe';
    debugPrint(line);
    _recent.add(line);
    if (_recent.length > recentLogLimit) _recent.removeAt(0);
  }

  // ------------------------------------------------------------------
  // 脱敏
  // ------------------------------------------------------------------

  /// 匹配日志里的 http(s) URL。
  static final RegExp _urlPattern = RegExp(r'''https?://[^\s"'<>)\]}]+''');

  /// 匹配 `cookie=...` / `Authorization: Bearer ...` / `stoken=...` 之类的键值。
  ///
  /// 三个细节缺一不可：
  /// - 键名**两侧允许出现引号**：JSON 里是 `"stoken":"xxx"`，键名后面紧跟的是
  ///   闭合引号而不是分隔符。早先的正则要求键名后**直接**是 `:` 或 `=`，于是
  ///   所有 JSON 形态（`{"stoken":"..."}`、`{"cookie":"..."}`）全部漏过、原样
  ///   落进日志（实测确认）。
  /// - 值**外侧的引号也要吃进去**，否则会留下半截引号把日志搞乱。
  /// - `Bearer` / `Basic` 前缀单独匹配，否则 `Authorization: Bearer xxx`
  ///   只会打码到 `Bearer`，真正的 token 留在日志里。
  ///
  /// 分组：1 键前引号、2 键名、3 键后引号、4 分隔符、5 值前引号、6 值、7 值后引号。
  static final RegExp _secretAssignment = RegExp(
    r'''(["']?)'''
    r'(cookie|authorization|set-cookie|bduss|stoken|access[_-]?token|appkey)'
    r'''(["']?)(\s*[:=]\s*)(?:(?:bearer|basic)\s+)?(["']?)([^"'\s,;]+)(["']?)''',
    caseSensitive: false,
  );

  /// 把文本里的敏感内容打码。
  ///
  /// - URL：丢弃 **查询串的值**（`download_url` 的时效签名、`x-oss-expires`、
  ///   `stoken` 都在这里）与 fragment，保留 scheme / host / path / 参数名。
  /// - 键值：`Cookie=xxx`、`Authorization: xxx`、JSON 的 `"stoken":"xxx"` 均整体打码。
  ///
  /// 这个方法是纯函数，方便单测覆盖。
  static String sanitize(String raw) {
    var out = raw.replaceAllMapped(
      _urlPattern,
      (m) => redactUrl(m.group(0)!),
    );
    out = out.replaceAllMapped(
      _secretAssignment,
      // 保留键与值两侧的引号、以及原分隔符（`:` 或 `=`），只把值换成占位符，
      // 这样 JSON 形态脱敏后仍是合法形态，日志可读性不塌。
      (m) => '${m.group(1)}${m.group(2)}${m.group(3)}'
          '${m.group(4)}${m.group(5)}<redacted>${m.group(7)}',
    );
    return out;
  }

  /// URL 脱敏：保留 scheme/host/port/path，查询参数的值全部替换为 `<redacted>`。
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return '<redacted-url>';
    final buf = StringBuffer('${uri.scheme}://${uri.host}');
    if (uri.hasPort) buf.write(':${uri.port}');
    buf.write(uri.path);
    if (uri.queryParameters.isNotEmpty) {
      buf.write('?');
      buf.write(
        uri.queryParameters.keys.map((k) => '$k=<redacted>').join('&'),
      );
    }
    return buf.toString();
  }

  // ------------------------------------------------------------------
  // 崩溃记录与轮转
  // ------------------------------------------------------------------

  /// 记录一次崩溃（或非致命异常），写入 `crash.log` 并按数量轮转。
  /// 返回写入的文件；失败返回 null（日志本身绝不能把主流程带崩）。
  Future<File?> recordCrash(
    Object error,
    StackTrace? stack, {
    String tag = 'Crash',
  }) async {
    try {
      final dir = await directoryProvider();
      if (!await dir.exists()) await dir.create(recursive: true);
      await _rotate(dir);

      final file = File('${dir.path}/$logFileName');
      final report = StringBuffer()
        ..writeln('===== $tag @ ${DateTime.now().toIso8601String()} =====')
        ..writeln(sanitize(error.toString()));
      if (stack != null) {
        // 只取前 30 帧，避免一个深栈把文件撑爆
        for (final line in stack.toString().split('\n').take(30)) {
          report.writeln(sanitize(line));
        }
      }
      if (_recent.isNotEmpty) {
        report.writeln('--- 最近日志（末 ${_recent.length} 条）---');
        for (final line in _recent) {
          report.writeln(line);
        }
      }
      report.writeln();
      await file.writeAsString(
        report.toString(),
        mode: FileMode.append,
        flush: true,
      );
      return file;
    } catch (e) {
      debugPrint('[Log] 写崩溃日志失败: $e');
      return null;
    }
  }

  /// 轮转：`crash.log` → `crash.1.log` → `crash.2.log`，最老的丢弃。
  /// 保证磁盘上最多 [maxFiles] 个日志文件。
  Future<void> _rotate(Directory dir) async {
    final base = File('${dir.path}/$logFileName');
    if (!await base.exists()) return;
    if (await base.length() == 0) return;

    final oldest = File('${dir.path}/crash.${maxFiles - 1}.log');
    if (await oldest.exists()) await oldest.delete();
    for (var i = maxFiles - 2; i >= 1; i--) {
      final from = File('${dir.path}/crash.$i.log');
      if (await from.exists()) {
        await from.rename('${dir.path}/crash.${i + 1}.log');
      }
    }
    await base.rename('${dir.path}/crash.1.log');
  }

  // ------------------------------------------------------------------
  // 读取与导出
  // ------------------------------------------------------------------

  /// 现有日志文件（新 → 旧）。
  Future<List<File>> logFiles() async {
    final dir = await directoryProvider();
    final files = <File>[];
    for (final name in _fileNames()) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) files.add(f);
    }
    return files;
  }

  /// 汇总全部日志文本（附在用户反馈里最实用）。
  Future<String> readAll() async {
    final files = await logFiles();
    final buf = StringBuffer();
    for (final f in files) {
      buf.writeln('===== ${f.uri.pathSegments.last} =====');
      try {
        buf.write(await f.readAsString());
      } catch (e) {
        buf.writeln('<读取失败: $e>');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// 导出：把汇总日志另存为带时间戳的文件，返回该文件。
  ///
  /// 之所以是「生成文件」而不是「弹分享」：分享需要系统分享/文件选择器，
  /// 本期不引入新依赖。拿到路径后可由 UI 层接分享或让用户手动取走。
  Future<File?> exportToFile() async {
    try {
      final content = await readAll();
      if (content.trim().isEmpty) return null;
      final dir = await directoryProvider();
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final out = File('${dir.path}/lingyun_log_$stamp.txt');
      await out.writeAsString(content, flush: true);
      return out;
    } catch (e) {
      debugPrint('[Log] 导出日志失败: $e');
      return null;
    }
  }

  /// 清空全部日志文件与内存缓冲。
  Future<void> clear() async {
    _recent.clear();
    try {
      final dir = await directoryProvider();
      for (final name in _fileNames()) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) await f.delete();
      }
    } catch (e) {
      debugPrint('[Log] 清空日志失败: $e');
    }
  }

  List<String> _fileNames() => [
        logFileName,
        for (var i = 1; i < maxFiles; i++) 'crash.$i.log',
      ];
}
