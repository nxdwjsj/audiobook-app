// 夸克网盘有声书资源爬虫（原型 / 独立脚本，不参与 App 打包）。
//
// 流程：发现分享链接 → 解析分享目录（递归）→ 统计音频文件 → 输出报告
//
// 用法：
//   dart run tool/quark_crawler.dart --keyword 鬼吹灯
//   dart run tool/quark_crawler.dart --links https://pan.quark.cn/s/xxx
//   dart run tool/quark_crawler.dart --links-file tool/links.txt --out tool/out.json
//   dart run tool/quark_crawler.dart --keyword 三体 --cookie "你的夸克Cookie"
//
// 说明：
// - 复用了 App 内 QuarkDriveService 的接口（sharepage/token + sharepage/detail）。
// - 日志不会打印 Cookie。
// - 分享是否可读取决于分享本身是否公开；需要登录态的分享请用 --cookie。
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const String _apiBase = 'https://drive-pc.quark.cn';

/// 必须用夸克 PC 客户端的 UA，否则部分接口/回源会拒绝。
const String _quarkUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) quark-cloud-drive/3.14.2 Chrome/112.0.5615.165 '
    'Electron/24.1.3.8 Safari/537.36 Channel/pckk_other_ch';

const String _browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 视为「音频」的扩展名。
const Set<String> _audioExts = {
  'mp3', 'm4a', 'm4b', 'aac', 'flac', 'wav', 'wma', 'ape',
  'ogg', 'opus', 'mka', 'ac3', 'amr', 'aiff', 'dsf',
};

// ---------------------------------------------------------------------------
// 数据结构
// ---------------------------------------------------------------------------

/// 一个待解析的分享。
class ShareLink {
  final String pwdId;
  final String? passcode;
  final String source;

  ShareLink(this.pwdId, {this.passcode, this.source = 'manual'});

  String get url => 'https://pan.quark.cn/s/$pwdId';
}

/// 分享里的一个文件。
class ShareFile {
  final String name;
  final String path;
  final int size;

  ShareFile(this.name, this.path, this.size);

  String get ext =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
  bool get isAudio => _audioExts.contains(ext);
}

/// 单个分享的解析结果。
class ShareReport {
  final ShareLink link;
  final String title;
  final List<ShareFile> files;
  String? error;

  ShareReport(this.link, this.title, this.files);

  List<ShareFile> get audioFiles => files.where((f) => f.isAudio).toList();

  int get audioBytes =>
      audioFiles.fold(0, (sum, f) => sum + f.size);

  /// 音频文件够多就认为是一个有声书分享。
  bool get looksLikeAudiobook => audioFiles.length >= 15;

  Map<String, dynamic> toJson() => {
        'url': link.url,
        'title': title,
        'source': link.source,
        'passcode': link.passcode,
        'audioCount': audioFiles.length,
        'otherCount': files.length - audioFiles.length,
        'audioBytes': audioBytes,
        'error': error,
        'files': [
          for (final f in audioFiles)
            {'name': f.name, 'path': f.path, 'size': f.size},
        ],
      };
}

// ---------------------------------------------------------------------------
// 夸克分享解析
// ---------------------------------------------------------------------------

class QuarkClient {
  QuarkClient({this.cookie});

  final String? cookie;
  final Map<String, String> _stokenCache = {};

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      'User-Agent': _quarkUa,
      'Referer': 'https://pan.quark.cn/',
    },
    validateStatus: (s) => s != null && s < 600,
  ));

  Map<String, String> get _headers => {
        if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
      };

  /// 分享码 → stoken（解析分享前必须拿到）。
  Future<String> _token(String pwdId, String? passcode) async {
    final cached = _stokenCache[pwdId];
    if (cached != null) return cached;

    final resp = await _dio.post(
      '$_apiBase/1/clouddrive/share/sharepage/token',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        '_t': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      },
      data: {'pwd_id': pwdId, 'passcode': passcode ?? ''},
      options: Options(headers: _headers),
    );
    final data = resp.data;
    if (data is! Map || data['code'] != 0) {
      throw _apiError('sharepage/token', resp);
    }
    final stoken = data['data']?['stoken']?.toString();
    if (stoken == null || stoken.isEmpty) {
      throw Exception('stoken 为空（分享可能失效或需要提取码）');
    }
    _stokenCache[pwdId] = stoken;
    return stoken;
  }

  /// 列出一个目录（自动翻页）。
  Future<List<Map<String, dynamic>>> _listDir(
    String pwdId,
    String stoken,
    String pdirFid,
  ) async {
    final out = <Map<String, dynamic>>[];
    const size = 100;
    var page = 1;
    while (true) {
      final resp = await _dio.get(
        '$_apiBase/1/clouddrive/share/sharepage/detail',
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'pwd_id': pwdId,
          'stoken': stoken,
          'pdir_fid': pdirFid,
          'force': '0',
          '_page': '$page',
          '_size': '$size',
          '_fetch_banner': '0',
          '_fetch_share': '0',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,file_name:asc',
          'ver': '2',
        },
        options: Options(headers: _headers),
      );
      final data = resp.data;
      if (data is! Map || data['code'] != 0) {
        throw _apiError('sharepage/detail', resp);
      }
      final list = (data['data']?['list'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      out.addAll(list);

      final total = (data['metadata']?['_total'] as num?)?.toInt();
      if (list.length < size) break;
      if (total != null && out.length >= total) break;
      page++;
      if (page > 50) break; // 安全上限：单目录 5000 条
    }
    return out;
  }

  /// 解析一个分享：返回标题 + 递归收集到的全部文件。
  Future<ShareReport> parse(ShareLink link, {int maxDepth = 4}) async {
    final stoken = await _token(link.pwdId, link.passcode);
    final files = <ShareFile>[];
    var title = '未知分享';

    Future<void> walk(String pdirFid, String parentPath, int depth) async {
      if (depth > maxDepth) return;
      final entries = await _listDir(link.pwdId, stoken, pdirFid);
      for (final e in entries) {
        final name = e['file_name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final childPath = parentPath.isEmpty ? name : '$parentPath/$name';
        if (e['dir'] == true) {
          await walk(e['fid']?.toString() ?? '0', childPath, depth + 1);
        } else {
          files.add(ShareFile(name, childPath, (e['size'] as num?)?.toInt() ?? 0));
        }
      }
    }

    // 根目录单独取一次，顺便拿到分享标题
    final rootEntries = await _listDir(link.pwdId, stoken, '0');
    for (final e in rootEntries) {
      final name = e['file_name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (e['dir'] == true) {
        await walk(e['fid']?.toString() ?? '0', name, 2);
      } else {
        files.add(ShareFile(name, name, (e['size'] as num?)?.toInt() ?? 0));
      }
    }

    // 标题：优先取第一个顶层目录名，其次用分享标题
    final firstDir = rootEntries.firstWhere(
      (e) => e['dir'] == true,
      orElse: () => const {},
    );
    if (firstDir['file_name'] != null) {
      title = firstDir['file_name'].toString();
    } else if (rootEntries.isNotEmpty) {
      title = rootEntries.first['file_name']?.toString() ?? title;
    }

    return ShareReport(link, title, files);
  }

  Never _apiError(String tag, Response resp) {
    final status = resp.statusCode ?? -1;
    final data = resp.data;
    if (data is Map) {
      final code = data['code'];
      final message = data['message'] ?? '';
      throw Exception('[$tag] HTTP $status code=$code $message');
    }
    final text = data?.toString() ?? '';
    throw Exception(
        '[$tag] HTTP $status 非 JSON: ${text.substring(0, text.length.clamp(0, 200))}');
  }
}

// ---------------------------------------------------------------------------
// 分享链接发现（用公开搜索引擎结果页抓 pan.quark.cn/s/xxx）
// ---------------------------------------------------------------------------

class Discovery {
  Discovery({this.cookie, this.verbose = false, this.withEngine = false});

  final String? cookie;
  final bool verbose;

  /// 是否启用搜索引擎渠道（默认关闭：反爬严重、命中率低）。
  final bool withEngine;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      'User-Agent': _browserUa,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    },
    validateStatus: (s) => s != null && s < 600,
  ));

  /// 关键词 → 分享链接列表。
  Future<List<ShareLink>> search(String keyword) async {
    final found = <String, ShareLink>{};

    // 1) B 站搜索接口：最稳定的渠道——分享帖简介里常直接贴夸克链接。
    print('  [发现] 渠道: bilibili 搜索接口');
    final biliQueries = <String>{
      '$keyword 夸克',
      '$keyword 夸克网盘',
      '$keyword 有声小说',
      keyword,
    };
    for (final q in biliQueries) {
      try {
        final links = await _bilibili(q);
        for (final l in links) {
          found.putIfAbsent(l.pwdId, () => l);
        }
        print('    「$q」 → ${links.length} 条');
      } catch (e) {
        print('    「$q」 失败: $e');
      }
      await _sleep(600);
    }

    // 2) 搜索引擎：默认关闭（反爬严重、命中率低），用 --engine 打开。
    if (!withEngine) return found.values.toList();

    print('  [发现] 渠道: 搜索引擎（可能被反爬）');
    final queries = <String>[
      'site:pan.quark.cn $keyword',
      '$keyword 夸克网盘 有声小说',
    ];

    final providers = <(String, Future<List<ShareLink>> Function(String))>[
      ('bing', _bing),
      ('360', _so360),
      ('sogou', _sogou),
    ];

    for (final q in queries) {
      for (final (name, fetch) in providers) {
        try {
          final links = await fetch(q);
          for (final l in links) {
            found.putIfAbsent(l.pwdId, () => l);
          }
          if (links.isNotEmpty) {
            print('    [$name] 「$q」 → ${links.length} 条');
          }
        } catch (e) {
          print('    [$name] 「$q」 失败: $e');
        }
        await _sleep(400);
      }
      if (found.length >= 40) break;
    }

    return found.values.toList();
  }

  /// B 站视频搜索：翻几页，把标题/简介/标签里的夸克链接抠出来。
  Future<List<ShareLink>> _bilibili(String keyword) async {
    final out = <ShareLink>[];
    for (var page = 1; page <= 2; page++) {
      final q = Uri.encodeComponent(keyword);
      final url = 'https://api.bilibili.com/x/web-interface/search/type'
          '?search_type=video&keyword=$q&page=$page&page_size=20';
      final body = await _biliGet(url);
      final data = jsonDecode(body);
      if (data is! Map || data['code'] != 0) {
        final code = data is Map ? data['code'] : '?';
        throw Exception('bilibili code=$code');
      }
      final results = (data['data']?['result'] as List<dynamic>? ?? []);
      if (results.isEmpty) break;

      final sb = StringBuffer();
      for (final r in results) {
        if (r is! Map) continue;
        sb.writeln(r['title'] ?? '');
        sb.writeln(r['description'] ?? '');
        sb.writeln(r['tag'] ?? '');
      }
      out.addAll(_extract(sb.toString(), 'bilibili'));
      await _sleep(400);
    }
    return out;
  }

  /// 带风控重试的 B 站接口请求：遇到 412 就换一个风控 Cookie 再试。
  Future<String> _biliGet(String url) async {
    var cookie = await _biliCookie();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _text(url, headers: {
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          if (cookie != null) 'Cookie': cookie,
        });
      } catch (e) {
        final is412 = e.toString().contains('412');
        if (!is412 || attempt == 2) rethrow;
        if (verbose) print('    [bilibili] 命中风控，换 Cookie 重试');
        _biliCookieCache = null;
        await _sleep(800);
        cookie = await _biliCookie();
      }
    }
    throw StateError('unreachable');
  }

  String? _biliCookieCache;

  /// 拿 B 站风控 Cookie：优先从首页 Set-Cookie 取，取不到就本地生成一份。
  /// 搜索接口缺 buvid3 会直接返回 HTTP 412。
  Future<String?> _biliCookie() async {
    if (_biliCookieCache != null) return _biliCookieCache;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await _dio.get<String>(
          'https://www.bilibili.com/',
          options: Options(
            responseType: ResponseType.plain,
            headers: {'User-Agent': _browserUa},
          ),
        );
        final cookies = resp.headers['set-cookie'] ?? const <String>[];
        final parts = <String>[];
        for (final c in cookies) {
          final first = c.split(';').first.trim();
          if (first.startsWith('buvid3=') ||
              first.startsWith('buvid4=') ||
              first.startsWith('b_nut=')) {
            parts.add(first);
          }
        }
        if (parts.isNotEmpty) {
          _biliCookieCache = parts.join('; ');
          if (verbose) {
            print('    [bilibili] 已取到风控 Cookie（${parts.length} 项）');
          }
          return _biliCookieCache;
        }
      } catch (e) {
        if (verbose) print('    [bilibili] 取 Cookie 失败: $e');
      }
      await _sleep(500);
    }

    // 兜底：本地生成，多数情况下也能绕过 412
    final rnd = Random();
    String hex(int n) => List.generate(
        n, (_) => rnd.nextInt(16).toRadixString(16).toUpperCase()).join();
    _biliCookieCache = 'buvid3=${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-'
        '${hex(12)}infoc; '
        'b_nut=${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    if (verbose) print('    [bilibili] 使用本地生成的风控 Cookie');
    return _biliCookieCache;
  }

  Future<List<ShareLink>> _bing(String query) async {
    final q = Uri.encodeComponent(query);
    final html = await _text('https://www.bing.com/search?q=$q&count=30');
    final html2 =
        await _text('https://www.bing.com/search?q=$q&count=30&first=11');
    final combined = '$html\n$html2';
    // Bing 把结果真实 URL 以 base64url 藏在 u=a1... 参数里，需解码后再匹配
    final parts = <String>[combined];
    final re = RegExp(r'u=a1([A-Za-z0-9_\-]+)');
    for (final m in re.allMatches(combined)) {
      final url = _b64UrlDecode(m.group(1)!);
      if (url != null) parts.add(url);
    }
    return _extract(parts.join('\n'), 'bing');
  }

  Future<List<ShareLink>> _sogou(String query) async {
    final q = Uri.encodeComponent(query);
    final html = await _text('https://www.sogou.com/web?query=$q');
    return _extract(html, 'sogou');
  }

  Future<List<ShareLink>> _so360(String query) async {
    final q = Uri.encodeComponent(query);
    final html = await _text('https://www.so.com/s?q=$q');
    return _extract(html, '360');
  }

  Future<String> _text(String url, {Map<String, String>? headers}) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
          ...?headers,
        },
      ),
    );
    final body = resp.data ?? '';
    if (verbose) {
      print('    GET $url → HTTP ${resp.statusCode}, ${body.length} 字符');
    }
    if ((resp.statusCode ?? 0) >= 400) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return body;
  }

  /// 从结果页 HTML 里抽取分享码，并尝试识别附近的「提取码」。
  List<ShareLink> _extract(String html, String source) {
    final out = <ShareLink>[];
    final seen = <String>{};
    final re = RegExp(r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)');
    final quarkMentions = 'quark'.allMatches(html).length;
    for (final m in re.allMatches(html)) {
      final pwdId = m.group(1)!;
      if (!seen.add(pwdId)) continue;
      // 链接前后 200 字符里找提取码
      final start = max(0, m.start - 200);
      final end = min(html.length, m.end + 200);
      final window = html.substring(start, end);
      final pwdMatch = RegExp(
        r'(?:提取码|密码|pwd|passcode)\s*[:：]?\s*([0-9a-zA-Z]{4})\b',
        caseSensitive: false,
      ).firstMatch(window);
      out.add(ShareLink(
        pwdId,
        passcode: pwdMatch?.group(1),
        source: source,
      ));
    }
    if (verbose) {
      print('    [$source] 匹配 ${out.length} 条；'
          '页面提及 quark $quarkMentions 次');
    }
    return out;
  }

  /// 解码 Bing 结果链接里的 base64url 参数。
  String? _b64UrlDecode(String s) {
    try {
      var t = s.replaceAll('-', '+').replaceAll('_', '/');
      while (t.length % 4 != 0) {
        t += '=';
      }
      return utf8.decode(base64.decode(t), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
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

  final keyword = opts['keyword'];
  final cookie = opts['cookie'] ?? Platform.environment['QUARK_COOKIE'];
  final limit = int.tryParse(opts['limit'] ?? '') ?? 20;
  final delayMs = int.tryParse(opts['delay'] ?? '') ?? 800;

  final links = <ShareLink>[];

  // 1) 手动指定的链接
  final linkArgs = opts['links'];
  if (linkArgs != null) {
    for (final raw in linkArgs.split(',')) {
      final l = _parseLinkArg(raw);
      if (l != null) links.add(l);
    }
  }
  final linksFile = opts['links-file'];
  if (linksFile != null) {
    final f = File(linksFile);
    if (f.existsSync()) {
      for (final line in f.readAsLinesSync()) {
        final l = _parseLinkArg(line.trim());
        if (l != null) links.add(l);
      }
    } else {
      print('[警告] 找不到链接文件: $linksFile');
    }
  }

  // 2) 搜索发现
  if (keyword != null && keyword.isNotEmpty) {
    print('== 发现阶段: 关键词「$keyword」 ==');
    final discovery = Discovery(
      cookie: cookie,
      verbose: opts.containsKey('verbose'),
      withEngine: opts.containsKey('engine'),
    );
    final found = await discovery.search(keyword);
    print('  合计发现 ${found.length} 条分享链接');
    links.addAll(found);
  }

  if (links.isEmpty) {
    print('没有可解析的链接。用 --keyword 或 --links 指定。');
    _printUsage();
    return;
  }

  // 去重
  final unique = <String, ShareLink>{};
  for (final l in links) {
    unique.putIfAbsent(l.pwdId, () => l);
  }
  var targets = unique.values.toList();
  if (targets.length > limit) targets = targets.sublist(0, limit);

  print('\n== 解析阶段: 共 ${targets.length} 个分享 ==');
  final client = QuarkClient(cookie: cookie);
  final reports = <ShareReport>[];

  for (var i = 0; i < targets.length; i++) {
    final link = targets[i];
    stdout.write('  [${i + 1}/${targets.length}] ${link.pwdId} ... ');
    try {
      final report = await client.parse(link);
      report.error = null;
      reports.add(report);
      print('${report.audioFiles.length} 个音频 / '
          '${_fmtSize(report.audioBytes)}（共 ${report.files.length} 个文件）'
          '  ← ${report.title}');
    } catch (e) {
      final report = ShareReport(link, '解析失败', [])..error = e.toString();
      reports.add(report);
      print('失败: $e');
    }
    await _sleep(delayMs);
  }

  // 3) 报告
  _printReport(reports);

  final outPath = opts['out'];
  if (outPath != null) {
    final payload = {
      'keyword': keyword,
      'generatedAt': DateTime.now().toIso8601String(),
      'shares': reports.map((r) => r.toJson()).toList(),
    };
    await File(outPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    print('\n已写出 JSON: $outPath');
  }

  exit(0);
}

void _printReport(List<ShareReport> reports) {
  final ok = reports.where((r) => r.error == null).toList();
  final audiobooks = ok.where((r) => r.looksLikeAudiobook).toList()
    ..sort((a, b) => b.audioFiles.length.compareTo(a.audioFiles.length));

  print('\n===== 结果汇总 =====');
  print('解析成功 ${ok.length} / ${reports.length}，'
      '其中疑似有声书（≥15 个音频）${audiobooks.length} 个');

  if (audiobooks.isEmpty) {
    final anyAudio = ok.where((r) => r.audioFiles.isNotEmpty).toList();
    if (anyAudio.isEmpty) {
      print('没有发现音频文件。可能是分享失效、需要提取码，或资源不是音频。');
    } else {
      print('发现若干含音频的分享（数量不足 15）：');
      for (final r in anyAudio) {
        print('  ${r.audioFiles.length} 个音频  ${r.title}  ${r.link.url}');
      }
    }
  } else {
    print('\n-- 推荐（按音频数排序）--');
    for (var i = 0; i < audiobooks.length; i++) {
      final r = audiobooks[i];
      print('${i + 1}. ${r.title}');
      print('   分享: ${r.link.url}'
          '${r.link.passcode != null ? '  提取码: ${r.link.passcode}' : ''}');
      print('   音频: ${r.audioFiles.length} 个 / ${_fmtSize(r.audioBytes)}'
          '   其他文件: ${r.files.length - r.audioFiles.length} 个');
      final sample = r.audioFiles.take(3).map((f) => f.name).join(' | ');
      print('   示例: $sample');
    }
  }

  final failed = reports.where((r) => r.error != null).toList();
  if (failed.isNotEmpty) {
    print('\n-- 解析失败 --');
    for (final r in failed) {
      print('  ${r.link.url}: ${r.error}');
    }
  }
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/// 支持 "https://pan.quark.cn/s/xxx" / "xxx" / "xxx|提取码" / "url?pwd=xxx"
ShareLink? _parseLinkArg(String raw) {
  if (raw.isEmpty) return null;
  var text = raw;
  String? passcode;

  // 显式的 |提取码
  final pipe = text.split('|');
  if (pipe.length >= 2) {
    text = pipe.first.trim();
    passcode = pipe[1].trim();
  }
  // url?pwd=xxxx
  final pwdQ = RegExp(r'[?&]pwd=([0-9a-zA-Z]{4})').firstMatch(text);
  if (pwdQ != null) passcode ??= pwdQ.group(1);

  final m = RegExp(r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)').firstMatch(text);
  if (m != null) return ShareLink(m.group(1)!, passcode: passcode);

  // 只给了分享码
  if (RegExp(r'^[0-9a-zA-Z_-]{6,}$').hasMatch(text)) {
    return ShareLink(text, passcode: passcode);
  }
  return null;
}

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
夸克网盘有声书资源爬虫

用法:
  dart run tool/quark_crawler.dart --keyword <关键词> [选项]
  dart run tool/quark_crawler.dart --links <分享链接[,链接2]> [选项]
  dart run tool/quark_crawler.dart --links-file <文件路径> [选项]

选项:
  --keyword <词>      关键词，用于搜索发现分享链接
  --links <链接>      直接指定夸克分享链接，多个用逗号分隔
  --links-file <路径> 从文件读取链接，每行一条（可写 "链接|提取码"）
  --limit <N>         最多解析多少个分享，默认 20
  --delay <毫秒>      每次请求间隔，默认 800
  --cookie <串>       夸克 Cookie（需要登录态的分享才用；也可用环境变量 QUARK_COOKIE）
  --out <路径>        把完整结果写成 JSON
  --engine            额外启用搜索引擎渠道（默认只用 B 站，反爬严重时可不加）
  --verbose           打印发现阶段的请求详情（诊断用）
  --help              显示帮助
''');
}

String _fmtSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

Future<void> _sleep(int ms) =>
    Future.delayed(Duration(milliseconds: ms + Random().nextInt(200)));