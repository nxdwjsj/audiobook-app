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

  /// 接口返回的对象类别（audio / video / doc ...），比扩展名更可靠。
  final String objCategory;

  /// 接口返回的 MIME（audio/mpeg 等）。
  final String formatType;

  ShareFile(
    this.name,
    this.path,
    this.size, {
    this.objCategory = '',
    this.formatType = '',
  });

  String get ext =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  /// 扩展名、对象类别、MIME 三者任一命中即视为音频，避免漏判。
  bool get isAudio =>
      _audioExts.contains(ext) ||
      objCategory == 'audio' ||
      formatType.startsWith('audio/');
}

/// 单个分享的解析结果。
class ShareReport {
  final ShareLink link;
  final String title;
  final List<ShareFile> files;
  String? error;

  /// 关键词命中次数（标题 + 文件名），0 表示与关键词无关。
  int keywordHits = 0;

  ShareReport(this.link, this.title, this.files);

  List<ShareFile> get audioFiles => files.where((f) => f.isAudio).toList();

  int get audioBytes =>
      audioFiles.fold(0, (sum, f) => sum + f.size);

  /// 音频文件够多就认为是一个有声书分享。
  bool get looksLikeAudiobook => audioFiles.length >= 15;

  /// 按关键词给分享打分：标题权重高，文件名逐条累加但有上限。
  void scoreKeyword(List<String> tokens) {
    if (tokens.isEmpty) return;
    var hits = 0;
    for (final t in tokens) {
      if (t.isEmpty) continue;
      if (title.contains(t)) hits += 5;
    }
    var fileHits = 0;
    for (final f in files) {
      if (tokens.any((t) => t.isNotEmpty && f.name.contains(t))) {
        fileHits++;
        if (fileHits >= 10) break; // 上限，避免大分享刷分
      }
    }
    keywordHits = hits + fileHits;
  }

  Map<String, dynamic> toJson() => {
        'url': link.url,
        'title': title,
        'source': link.source,
        'passcode': link.passcode,
        'keywordHits': keywordHits,
        'audioCount': audioFiles.length,
        'otherCount': files.length - audioFiles.length,
        'audioBytes': audioBytes,
        'error': error,
        // 非音频文件名抽样，便于排查「有文件但识别不出音频」的情况
        'otherSample': [
          for (final f in files.where((f) => !f.isAudio).take(5)) f.name,
        ],
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
    try {
      return await _tokenOnce(pwdId, passcode);
    } catch (e) {
      // 提取码是从页面上下文猜的，可能张冠李戴（41007）。
      // 很多分享其实是公开的，附近的四位码属于别的链接 → 退回无提取码重试。
      if (passcode != null &&
          passcode.isNotEmpty &&
          e.toString().contains('41007')) {
        return await _tokenOnce(pwdId, null);
      }
      rethrow;
    }
  }

  Future<String> _tokenOnce(String pwdId, String? passcode) async {
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

    ShareFile toFile(Map<String, dynamic> e, String path) => ShareFile(
          e['file_name']?.toString() ?? '',
          path,
          (e['size'] as num?)?.toInt() ?? 0,
          objCategory: e['obj_category']?.toString() ?? '',
          formatType: e['format_type']?.toString() ?? '',
        );

    // 目录遍历用限并发工作池：上万文件的大分享串行递归太慢。
    final queue = <(String, String, int)>[];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (fid, path, depth) = queue.removeLast();
        if (depth > maxDepth) continue;
        final entries = await _listDir(link.pwdId, stoken, fid);
        for (final e in entries) {
          final name = e['file_name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final childPath = path.isEmpty ? name : '$path/$name';
          if (e['dir'] == true) {
            queue.add((e['fid']?.toString() ?? '0', childPath, depth + 1));
          } else {
            files.add(toFile(e, childPath));
          }
        }
      }
    }

    // 根目录单独取一次，顺便拿到分享标题
    final rootEntries = await _listDir(link.pwdId, stoken, '0');
    for (final e in rootEntries) {
      final name = e['file_name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (e['dir'] == true) {
        queue.add((e['fid']?.toString() ?? '0', name, 2));
      } else {
        files.add(toFile(e, name));
      }
    }
    await Future.wait(List.generate(4, (_) => worker()));

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
      '$keyword 有声书 夸克',
      '$keyword 广播剧 夸克',
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

    // 2) 第一故事（yigushi.com）站内搜索：文章页正文直接贴夸克链接，
    //    对「书名」类关键词命中率远高于 B 站简介。
    print('  [发现] 渠道: yigushi.com 站内搜索');
    try {
      final links = await _yigushi(keyword);
      for (final l in links) {
        found.putIfAbsent(l.pwdId, () => l);
      }
      print('    「$keyword」 → ${links.length} 条');
    } catch (e) {
      print('    「$keyword」 失败: $e');
    }
    await _sleep(600);

    // 3) Mp3故事网（Z-Blog 站内搜索，同样正文贴夸克链接）
    print('  [发现] 渠道: mp3.yangzhiyi.com 站内搜索');
    try {
      final links = await _yangzhiyi(keyword);
      for (final l in links) {
        found.putIfAbsent(l.pwdId, () => l);
      }
      print('    「$keyword」 → ${links.length} 条');
    } catch (e) {
      print('    「$keyword」 失败: $e');
    }
    await _sleep(600);

    // 4) slowread.net 有声书合集页：静态大列表，标题与夸克链接成对出现，无需搜索
    print('  [发现] 渠道: slowread.net 合集页');
    try {
      final links = await _slowread(keyword);
      for (final l in links) {
        found.putIfAbsent(l.pwdId, () => l);
      }
      print('    「$keyword」 → ${links.length} 条');
    } catch (e) {
      print('    「$keyword」 失败: $e');
    }
    await _sleep(600);

    // 5) 放空一夏 fangkong.cc：广播剧/有声书全文检索，搜索页直接含夸克链接
    print('  [发现] 渠道: fangkong.cc 站内搜索');
    try {
      final links = await _fangkong(keyword);
      for (final l in links) {
        found.putIfAbsent(l.pwdId, () => l);
      }
      print('    「$keyword」 → ${links.length} 条');
    } catch (e) {
      print('    「$keyword」 失败: $e');
    }
    await _sleep(600);

    // 6) 搜索引擎：默认关闭（反爬严重、命中率低），用 --engine 打开。
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

  /// 第一故事站内搜索 → 命中文章页 → 抠出夸克链接。
  /// Destoon CMS：搜索页为 /<模块>/search.php?kw=xxx，结果条目是带 title 的 <a>；
  /// 文章页正文里直接贴 pan.quark.cn/s/xxx。
  Future<List<ShareLink>> _yigushi(String keyword) async {
    final out = <ShareLink>[];
    final seenArticle = <String>{};
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .take(3)
        .toList();
    // 站内搜索对多词关键词匹配差，按 token 逐个搜；整词也试一次
    final queries = {...tokens, if (tokens.length > 1) keyword};
    // 有声小说 + 评书 + 戏曲 + 儿童故事四个板块，覆盖绝大多数音频资源
    for (final q in queries) {
      for (final mod in const ['youshengxiaoshuo', 'soft', 'xiqu', 'baby']) {
        final kw = Uri.encodeComponent(q);
        final html =
            await _text('https://www.yigushi.com/$mod/search.php?kw=$kw');
        final re = RegExp(
            r'<a href="(https://www\.yigushi\.com/[^"]+\.html)"[^>]*?target="_blank"[^>]*?title="([^"]+)"');
        final articles = <String>[];
        for (final m in re.allMatches(html)) {
          final title = m.group(2)!;
          // 站内搜索匹配较宽松，只保留标题确实含关键词任一 token 的条目
          if (!tokens.any((t) => title.contains(t))) continue;
          if (!seenArticle.add(m.group(1)!)) continue;
          articles.add(m.group(1)!);
          if (articles.length >= 3) break; // 单板块单词最多看 3 篇，控制请求量
        }
        if (verbose) print('    [yigushi/$mod] 「$q」命中文章 ${articles.length} 篇');
        for (final url in articles) {
          try {
            final page = await _text(url);
            out.addAll(_extract(page, 'yigushi'));
          } catch (e) {
            if (verbose) print('    [yigushi] 文章页失败 $url: $e');
          }
          await _sleep(400);
        }
        await _sleep(400);
      }
    }
    return out;
  }

  /// Mp3故事网（Z-Blog CMS）：POST 搜索 → 结果页 <h2><a title=...> → 文章页抠链接。
  Future<List<ShareLink>> _yangzhiyi(String keyword) async {
    final out = <ShareLink>[];
    final tokens = keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    for (final q in tokens.take(2)) {
      final resp = await _dio.post<String>(
        'https://mp3.yangzhiyi.com/zb_system/cmd.php?act=search',
        data: {'q': q},
        options: Options(
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
          headers: {'User-Agent': _browserUa},
        ),
      );
      if ((resp.statusCode ?? 0) >= 400) continue;
      final html = resp.data ?? '';
      final re = RegExp(
          r'<h2[^>]*>\s*<a href="(https://mp3\.yangzhiyi\.com/[^"]+\.html)"[^>]*title="([^"]+)"');
      final articles = <String>[];
      for (final m in re.allMatches(html)) {
        final title = m.group(2)!;
        // 该站搜索会匹配简介，只认标题命中的条目保证精度
        if (!tokens.any((t) => title.contains(t))) continue;
        articles.add(m.group(1)!);
        if (articles.length >= 3) break;
      }
      if (verbose) print('    [yangzhiyi] 「$q」命中文章 ${articles.length} 篇');
      for (final url in articles) {
        try {
          final page = await _text(url);
          out.addAll(_extract(page, 'yangzhiyi'));
        } catch (e) {
          if (verbose) print('    [yangzhiyi] 文章页失败 $url: $e');
        }
        await _sleep(400);
      }
      await _sleep(400);
    }
    return out;
  }

  /// slowread.net 有声书合集页：<span>标题</span> 紧跟夸克链接，直接成对抽取。
  Future<List<ShareLink>> _slowread(String keyword) async {
    final tokens = keyword.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final html = await _text('https://slowread.net/k/audiobook.html');
    final re = RegExp(
        r"<span>([^<]+)</span>\s*<a href='(https://pan\.quark\.cn/s/[0-9a-zA-Z_-]+)'");
    final out = <ShareLink>[];
    for (final m in re.allMatches(html)) {
      final title = m.group(1)!;
      if (!tokens.any((t) => title.contains(t))) continue;
      final pwdId = m.group(2)!.split('/').last;
      out.add(ShareLink(pwdId, source: 'slowread'));
      if (out.length >= 5) break;
    }
    if (verbose) print('    [slowread] 命中 ${out.length} 条');
    return out;
  }

  /// 放空一夏（fangkong.cc）：广播剧/有声书全文检索站，
  /// 搜索页 /s/<关键词>.html 的 HTML 里直接带 pan.quark.cn 链接，无需再进详情页。
  Future<List<ShareLink>> _fangkong(String keyword) async {
    final kw = Uri.encodeComponent(keyword);
    final html = await _text('https://fangkong.cc/s/$kw.html');
    return _extract(html, 'fangkong');
  }

  /// 直接抓任意页面里的夸克链接（--pages）：用于临时接入新的聚合站，
  /// 不需要为每个站单独写适配器。不做关键词过滤——页面由调用者自行挑选。
  Future<List<ShareLink>> pages(List<String> urls) async {
    final out = <ShareLink>[];
    for (final u in urls) {
      try {
        final html = await _text(u);
        final links = _extract(html, 'page');
        out.addAll(links);
        print('    $u → ${links.length} 条');
      } catch (e) {
        print('    $u 失败: $e');
      }
      await _sleep(400);
    }
    return out;
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

  // 2.5) 任意页面直抓（--pages）：临时接入新聚合站，无需写适配器
  final pagesArg = opts['pages'];
  if (pagesArg != null && pagesArg.isNotEmpty) {
    print('== 发现阶段: 直抓页面 ==');
    final pageDiscovery = Discovery(
      cookie: cookie,
      verbose: opts.containsKey('verbose'),
    );
    links.addAll(await pageDiscovery.pages(pagesArg.split(',')));
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
  // 策展类渠道（站内搜索/合集页）精度远高于 B 站简介里的链接，
  // 优先解析，否则会被 --limit 按发现顺序截掉。组内保持原顺序。
  const priority = {'fangkong': 0, 'yigushi': 0, 'slowread': 0, 'yangzhiyi': 0, 'page': 0};
  final indexed = [for (var i = 0; i < targets.length; i++) (i, targets[i])];
  indexed.sort((a, b) {
    final c = (priority[a.$2.source] ?? 1).compareTo(priority[b.$2.source] ?? 1);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  targets = [for (final e in indexed) e.$2];
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

  // 3) 关键词打分 + 报告
  final tokens = (keyword ?? '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  for (final r in reports) {
    r.scoreKeyword(tokens);
  }
  _printReport(reports, tokens);

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

void _printReport(List<ShareReport> reports, List<String> tokens) {
  final ok = reports.where((r) => r.error == null).toList();
  final audiobooks = ok.where((r) => r.looksLikeAudiobook).toList()
    ..sort((a, b) {
      // 先按关键词命中数，再按音频数
      final c = b.keywordHits.compareTo(a.keywordHits);
      if (c != 0) return c;
      return b.audioFiles.length.compareTo(a.audioFiles.length);
    });

  final matched = audiobooks.where((r) => r.keywordHits > 0).toList();
  final unrelated = audiobooks.where((r) => r.keywordHits == 0).toList();

  print('\n===== 结果汇总 =====');
  print('解析成功 ${ok.length} / ${reports.length}，'
      '其中疑似有声书（≥15 个音频）${audiobooks.length} 个'
      '${tokens.isNotEmpty ? '，命中关键词 ${matched.length} 个' : ''}');

  if (audiobooks.isEmpty) {
    final anyAudio = ok.where((r) => r.audioFiles.isNotEmpty).toList();
    if (anyAudio.isEmpty) {
      print('没有发现音频文件。可能是分享失效、需要提取码，或资源不是音频。');
      // 打印非音频抽样，帮助判断是「没音频」还是「识别不出音频」
      for (final r in ok.where((r) => r.files.isNotEmpty)) {
        final sample = r.files.take(3).map((f) => f.name).join(' | ');
        print('  [非音频抽样] ${r.title}: $sample');
      }
    } else {
      print('发现若干含音频的分享（数量不足 15）：');
      for (final r in anyAudio) {
        print('  ${r.audioFiles.length} 个音频  ${r.title}  ${r.link.url}');
      }
    }
  } else {
    if (matched.isNotEmpty) {
      print('\n-- 命中关键词（推荐）--');
      _printShareList(matched);
    }
    if (unrelated.isNotEmpty) {
      print('\n-- 其他疑似有声书（与关键词无关，仅供参考）--');
      _printShareList(unrelated);
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

void _printShareList(List<ShareReport> list) {
  for (var i = 0; i < list.length; i++) {
    final r = list[i];
    print('${i + 1}. ${r.title}（关键词命中 ${r.keywordHits}）');
    print('   分享: ${r.link.url}'
        '${r.link.passcode != null ? '  提取码: ${r.link.passcode}' : ''}');
    print('   音频: ${r.audioFiles.length} 个 / ${_fmtSize(r.audioBytes)}'
        '   其他文件: ${r.files.length - r.audioFiles.length} 个');
    final sample = r.audioFiles.take(3).map((f) => f.name).join(' | ');
    print('   示例: $sample');
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
  --pages <URL>     直接抓取任意页面里的夸克链接，多个用逗号分隔（临时接入新聚合站）
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