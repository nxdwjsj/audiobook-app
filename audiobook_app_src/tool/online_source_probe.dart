// 在线听书源探测脚本（原型 / 独立脚本，不参与 App 打包）。
//
// 目的：验证「在线听书网站」能否被爬取并接入 App（书名 / 目录 / 音频直链）。
// 与 quark_crawler.dart 并列，属于同一套「先评估、后接入」的验证工具。
//
// 用法：
//   dart run tool/online_source_probe.dart --keyword 鬼吹灯
//   dart run tool/online_source_probe.dart --keyword 鬼吹灯 --limit 5
//   dart run tool/online_source_probe.dart --album 34778353
//   dart run tool/online_source_probe.dart --keyword 鬼吹灯 --play 3     # 实测前 3 章音频可播放性
//   dart run tool/online_source_probe.dart --keyword 鬼吹灯 --out tool/online_out.json
//
// 说明：
// - 只做只读探测，不下载完整音频（--play 时仅取前 64KB 校验可播放性）。
// - 只收集免费内容：付费/VIP 专辑（albumPayType/albumVipPayType）整体跳过，
//   章节级以 isPaid 为准剔除付费集（isFree 在付费专辑里也常为 true，不可信）。
// - 最终结论（2026-09）：纯免费听书网站全部不可用，喜马拉雅属付费/免费混合平台，
//   按「只爬免费网站」要求不接入 App。本脚本仅作技术验证工具保留。
// - 日志不打印任何 Cookie / 签名。
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 必须用移动端 UA，PC 端接口会要求 webtk 签名。
const String _mobileUa =
    'Mozilla/5.0 (Linux; Android 12; SM-G975F) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

const String _ximaHost = 'https://www.ximalaya.com';
const String _ximaMobileHost = 'https://mobile.ximalaya.com';

// ---------------------------------------------------------------------------
// 数据结构
// ---------------------------------------------------------------------------

/// 一本书（专辑）的探测结果。
class AlbumReport {
  final int id;
  final String title;
  final String author;
  final String cover;
  int trackCount;
  final bool isPaid;
  final List<TrackInfo> tracks;
  String? error;

  /// 音频实测：成功拿到可播放字节的章节数。
  int playableCount = 0;

  /// 音频实测：被拒绝（付费/无权限）的章节数。
  int blockedCount = 0;

  AlbumReport({
    required this.id,
    required this.title,
    this.author = '',
    this.cover = '',
    this.trackCount = 0,
    this.isPaid = false,
    List<TrackInfo>? tracks,
  }) : tracks = tracks ?? [];

  /// 判定「够格当一本有声书」：章节数 >= 15。
  bool get looksLikeAudiobook => trackCount >= 15;
}

/// 一个章节。
class TrackInfo {
  final int id;
  final String title;
  final int duration;

  /// 免费标记（服务端在付费专辑里也常为 true，仅作参考，判定以 [isPaid] 为准）。
  final bool isFree;

  /// 是否付费章节（以此为准做免费过滤）。
  final bool isPaid;

  TrackInfo({
    required this.id,
    required this.title,
    this.duration = 0,
    this.isFree = true,
    this.isPaid = false,
  });

  String get durationText {
    if (duration <= 0) return '未知';
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m分$s秒';
  }
}

/// 音频直链探测结果。
class StreamProbe {
  final int trackId;
  final String title;
  bool ok = false;
  String kind = '';
  String note = '';
  int contentType = 0;
  String mime = '';
  int bytes = 0;
  int totalSize = 0;
  bool rangeSupported = false;

  StreamProbe(this.trackId, this.title);
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (_) => true,
    headers: {
      'User-Agent': _mobileUa,
      'Referer': '$_ximaHost/',
    },
  ));

  final keyword = opts['keyword'] as String?;
  final albumArg = opts['album'] as String?;
  final limit = int.tryParse('${opts['limit'] ?? 5}') ?? 5;
  final playCount = int.tryParse('${opts['play'] ?? 0}') ?? 0;
  final outPath = opts['out'] as String?;

  if (keyword == null && albumArg == null) {
    print('用法: dart run tool/online_source_probe.dart --keyword 鬼吹灯 [--limit 5] [--play 3] [--out out.json]');
    print('      dart run tool/online_source_probe.dart --album 34778353');
    exit(0);
  }

  print('=== 喜马拉雅在线源探测（只读）===');

  final results = <AlbumReport>[];

  if (albumArg != null) {
    final id = int.tryParse(albumArg);
    if (id == null) {
      print('专辑 ID 非法: $albumArg');
      exit(1);
    }
    print('直接解析专辑: $id');
    final r = await _fetchAlbum(dio, id);
    if (r != null) results.add(r);
  } else {
    print('搜索关键词: $keyword');
    final albums = await _searchAlbums(dio, keyword!, limit: limit);
    print('搜索命中专辑: ${albums.length} 个');
    for (final a in albums) {
      final r = await _fetchAlbum(dio, a.$1, fallbackTitle: a.$2);
      if (r != null) results.add(r);
    }
  }

  // ---- 音频实测 ----
  if (playCount > 0) {
    for (final r in results) {
      if (r.tracks.isEmpty) continue;
      final take = r.tracks.take(playCount).toList();
      print('\n--- 音频可播放性实测: ${r.title}（前 ${take.length} 章）---');
      for (final t in take) {
        final p = await _probeStream(dio, t.id, t.title);
        if (p.ok) {
          r.playableCount++;
        } else {
          r.blockedCount++;
        }
        final tag = p.ok ? '✅ 可播' : '❌ 不可播';
        print('  $tag  ${p.title}  [${p.kind}] ${p.note}');
      }
    }
  }

  // ---- 汇总 ----
  _printSummary(results, playCount > 0);

  // ---- 导出 ----
  if (outPath != null) {
    final data = {
      'generatedAt': DateTime.now().toIso8601String(),
      'keyword': keyword,
      'albums': results
          .map((r) => {
                'id': r.id,
                'title': r.title,
                'author': r.author,
                'cover': r.cover,
                'trackCount': r.trackCount,
                'isPaid': r.isPaid,
                'looksLikeAudiobook': r.looksLikeAudiobook,
                'playableCount': r.playableCount,
                'blockedCount': r.blockedCount,
                'error': r.error,
                'sampleTracks': r.tracks
                    .take(5)
                    .map((t) => {
                          'id': t.id,
                          'title': t.title,
                          'duration': t.duration,
                          'isPaid': t.isPaid,
                        })
                    .toList(),
              })
          .toList(),
    };
    await File(outPath).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    print('\n已导出: $outPath');
  }
}

// ---------------------------------------------------------------------------
// 喜马拉雅：搜索
// ---------------------------------------------------------------------------

/// 搜索专辑，返回 (专辑ID, 标题)。
Future<List<(int, String)>> _searchAlbums(
  Dio dio,
  String keyword, {
  int limit = 5,
}) async {
  final out = <(int, String)>[];
  try {
    final resp = await dio.get(
      '$_ximaHost/revision/search',
      queryParameters: {
        'kw': keyword,
        'page': 1,
        'rows': limit,
        'core': 'album',
        'spellchecker': 'true',
        'condition': 'relation',
      },
    );
    final body = _asMap(resp.data);
    if (body == null || body['ret'] != 200) {
      print('搜索返回异常: ret=${body?['ret']} msg=${body?['msg']}');
      return out;
    }
    final docs = _dig(body, ['data', 'result', 'response', 'docs']);
    if (docs is! List) {
      print('搜索结果结构不符（docs 缺失）');
      return out;
    }
    for (final d in docs) {
      if (d is! Map) continue;
      final id = _asInt(d['album_id'] ?? d['id']);
      final title = '${d['title'] ?? ''}';
      if (id != null && title.isNotEmpty) out.add((id, title));
    }
  } catch (e) {
    print('搜索失败: ${_brief(e)}');
  }
  return out;
}

// ---------------------------------------------------------------------------
// 喜马拉雅：专辑详情 + 章节列表
// ---------------------------------------------------------------------------

Future<AlbumReport?> _fetchAlbum(
  Dio dio,
  int albumId, {
  String fallbackTitle = '',
}) async {
  // ① 专辑信息
  var title = fallbackTitle;
  var author = '';
  var cover = '';
  var trackCount = 0;
  var isPaid = false;
  try {
    final resp = await dio.get('$_ximaHost/revision/album/v1/simple',
        queryParameters: {'albumId': albumId});
    final body = _asMap(resp.data);
    if (body != null && body['ret'] == 200) {
      final info = _dig(body, ['data', 'albumDetailInfo', 'albumInfo']) ??
          _dig(body, ['data', 'albumPageMainInfo']);
      if (info is Map) {
        title = '${info['albumTitle'] ?? title}';
        cover = '${info['cover'] ?? ''}';
        // 章节总数：详情接口的 statCountInfo.trackCount 优先（部分结构里没有该字段，靠章节接口兜底）
        trackCount = _asInt(
                _dig(body, ['data', 'albumDetailInfo', 'statCountInfo', 'trackCount'])) ??
            _asInt(info['tracksCount']) ??
            0;
        // 付费判定：兼容新旧两种接口结构。
        // 旧版：albumInfo.albumPayType / albumVipPayType / 顶层 albumPayType / isVipPrivileges
        // 新版（albumPageMainInfo）：isPaid / vipType / priceOp 存在即付费
        final albumPayType = _asInt(info['albumPayType']) ??
            _asInt(_dig(body, ['data', 'albumPayType'])) ??
            0;
        final albumVipPayType = _asInt(info['albumVipPayType']) ??
            _asInt(_dig(body, ['data', 'albumVipPayType'])) ??
            0;
        final vipPrivileges = _dig(body, ['data', 'isVipPrivileges']) == true;
        final isPaidMain =
            info['isPaid'] == true || info['vipType'] != 0 || info['priceOp'] is Map;
        isPaid = albumPayType != 0 ||
            albumVipPayType != 0 ||
            vipPrivileges ||
            isPaidMain;
      }
      final anchor = _dig(body, ['data', 'albumPageMainInfo', 'anchorName']) ??
          _dig(body, ['data', 'anchorInfo', 'userInfo']) ??
          _dig(body, ['data', 'albumDetailInfo', 'anchorInfo', 'userInfo']) ??
          _dig(body, ['data', 'albumPageMainInfo', 'anchorInfo']);
      if (anchor is Map) {
        author = '${anchor['anchorName'] ?? anchor['nickname'] ?? ''}';
      } else if (anchor != null) {
        author = '$anchor';
      }
    }
  } catch (e) {
    return null;
  }

  final report = AlbumReport(
    id: albumId,
    title: title.isEmpty ? '专辑$albumId' : title,
    author: author,
    cover: cover,
    trackCount: trackCount,
    isPaid: isPaid,
  );

  // 付费专辑：按「不爬付费内容」规则整体跳过，不拉章节、不探测音频
  if (isPaid) {
    report.error = '付费专辑（albumPayType/VIP），按规则跳过，不收录';
    return report;
  }

  // ② 章节列表（移动端接口，pc 端要 webtk 签名）
  try {
    final resp = await dio.get(
      '$_ximaMobileHost/mobile/v1/album/track/ts-1',
      queryParameters: {
        'albumId': albumId,
        'pageId': 1,
        'pageSize': 50,
        'isAsc': true,
      },
      options: Options(headers: {'Referer': '$_ximaMobileHost/'}),
    );
    final body = _asMap(resp.data);
    // 章节总数以章节接口 totalCount 为准（部分专辑详情接口不返回该值）
    final totalCount = _asInt(_dig(body, ['data', 'totalCount'])) ?? 0;
    if (totalCount > report.trackCount) report.trackCount = totalCount;
    final list = _dig(body, ['data', 'list']);
    if (list is List) {
      for (final t in list) {
        if (t is! Map) continue;
        final id = _asInt(t['trackId'] ?? t['id']);
        if (id == null) continue;
        // 只保留免费章节：以 isPaid 为准（isFree 在付费专辑里也常为 true，不可信）
        if (t['isPaid'] == true) continue;
        report.tracks.add(TrackInfo(
          id: id,
          title: '${t['title'] ?? ''}',
          duration: _asInt(t['duration']) ?? 0,
          isFree: t['isFree'] == true,
          isPaid: false,
        ));
      }
      if (report.trackCount == 0) report.trackCount = report.tracks.length;
    }
  } catch (e) {
    report.error = '章节列表失败: ${_brief(e)}';
  }

  return report;
}

// ---------------------------------------------------------------------------
// 喜马拉雅：音频直链探测
// ---------------------------------------------------------------------------

/// 探测单个章节能否拿到可播放音频。
Future<StreamProbe> _probeStream(Dio dio, int trackId, String title) async {
  final p = StreamProbe(trackId, title);
  try {
    // 该接口 302 跳转到带签名的 CDN 直链，Dio 默认自动跟随
    final resp = await dio.get(
      '$_ximaMobileHost/mobile/redirect/free/play/$trackId/0',
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        headers: {
          'Referer': '$_ximaMobileHost/',
          'Range': 'bytes=0-65535',
        },
        validateStatus: (_) => true,
      ),
    );

    p.contentType = resp.statusCode ?? 0;
    p.mime = '${resp.headers.value('content-type')}';
    p.rangeSupported = (resp.statusCode == 206) ||
        '${resp.headers.value('accept-ranges')}'.contains('bytes');

    // 206 时 content-length 只是分片长度，总大小要从 Content-Range 的 "/总长" 取
    final contentRange = '${resp.headers.value('content-range')}';
    var total = int.tryParse('${resp.headers.value('content-length')}');
    final slash = contentRange.lastIndexOf('/');
    if (slash >= 0) {
      final t = int.tryParse(contentRange.substring(slash + 1));
      if (t != null && t > 0) total = t;
    }

    final data = resp.data;
    final bytes = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : Uint8List(0));
    p.bytes = bytes.length;
    p.totalSize = total ?? bytes.length;

    if (bytes.length >= 12) {
      // M4A/MP4 容器：开头 4 字节长度 + 'ftyp'
      final isFtyp = bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70;
      // MP3：ID3 或帧同步
      final isId3 = bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33;
      final isMp3Frame = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;

      if (isFtyp) {
        p.ok = true;
        p.kind = 'M4A';
        p.note = '${(p.totalSize / 1024 / 1024).toStringAsFixed(1)}MB'
            '${p.rangeSupported ? " 支持Range" : " 无Range"}';
      } else if (isId3 || isMp3Frame) {
        p.ok = true;
        p.kind = 'MP3';
        p.note = '${(p.totalSize / 1024 / 1024).toStringAsFixed(1)}MB'
            '${p.rangeSupported ? " 支持Range" : " 无Range"}';
      } else {
        p.kind = '未知';
        // 服务端可能返回 JSON 错误（如 VIP 拦截），把可读文本拼进备注便于定位
        final preview =
            utf8.decode(bytes.take(200).toList(), allowMalformed: true).trim();
        p.note = '非法音频数据（前 8 字节: '
            '${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}）'
            '${preview.isNotEmpty ? ' 内容: $preview' : ''}';
      }
    } else {
      p.kind = '空';
      p.note = '状态码 ${p.contentType}，返回 ${bytes.length} 字节';
    }
  } catch (e) {
    p.kind = '异常';
    p.note = _brief(e);
  }
  return p;
}

// ---------------------------------------------------------------------------
// 汇总输出
// ---------------------------------------------------------------------------

void _printSummary(List<AlbumReport> results, bool didPlayProbe) {
  print('\n${'=' * 78}');
  print('汇总报告（喜马拉雅 / 移动端接口 / 无登录 / 仅免费内容）');
  print('=' * 78);

  if (results.isEmpty) {
    print('无结果。可能原因：关键词无命中，或接口变动。');
    return;
  }

  var audioOk = 0;
  print('${'书名'.padRight(30)}${'章节'.padLeft(6)}${'类型'.padLeft(9)}${'可当书'.padLeft(8)}${'音频实测'.padLeft(12)}');
  print('-' * 78);
  for (final r in results) {
    final name = r.title.length > 14 ? '${r.title.substring(0, 14)}…' : r.title;
    final type = r.isPaid ? '付费跳过' : '免费';
    final audiobook = r.looksLikeAudiobook ? '是' : '否';
    var playCol = '—';
    if (didPlayProbe && r.tracks.isNotEmpty) {
      playCol = '${r.playableCount}可播/${r.blockedCount}拒绝';
      if (r.playableCount > 0) audioOk++;
    }
    print('${name.padRight(30)}${r.trackCount.toString().padLeft(6)}'
        '${type.padLeft(9)}${audiobook.padLeft(8)}${playCol.padLeft(12)}');
  }
  print('-' * 78);

  final freeBooks = results.where((r) => !r.isPaid && r.looksLikeAudiobook).length;
  final paidSkipped = results.where((r) => r.isPaid).length;
  print('专辑总数: ${results.length}，免费且章节够当一本有声书的: $freeBooks，付费跳过: $paidSkipped');

  if (didPlayProbe) {
    print('音频实测可播的专辑: $audioOk / ${results.where((r) => r.tracks.isNotEmpty).length}');
    print('');
    print('结论提示：');
    print('  · 已按「不爬付费内容」规则过滤：付费/VIP 专辑整体跳过，章节以 isPaid 为准剔除付费集。');
    print('  · 若「音频实测」列出现 可播，说明该源可直连播放，具备接入 App 的可行性。');
    print('  · 若全为「拒绝」，通常是该专辑为付费内容（VIP），需换免费专辑验证。');
  }

  print('');
  print('最终结论（2026-09 实测）：不扩展在线听书源');
  print('  · 纯免费听书网站（懒人听书/评书网/tingzh 等）均被反爬拦截或网络不可达；');
  print('  · 喜马拉雅虽可打通搜索→章节→音频直链，但属付费/免费混合平台，');
  print('    专辑字段标「免费」的内容音频接口仍可能返回 ret:130 拒绝，甄别成本高；');
  print('  · 按「只爬免费网站、付费内容不碰」的要求，本脚本仅作技术验证保留，');
  print('    不接入 App；App 继续使用网盘直接播放模式。');
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

/// 安全转 Map（接口可能返回 String，需要二次 decode）。
Map<String, dynamic>? _asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry('$k', val));
  if (v is String && v.isNotEmpty) {
    try {
      final d = jsonDecode(v);
      if (d is Map) return d.map((k, val) => MapEntry('$k', val));
    } catch (_) {}
  }
  return null;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 按路径逐层取值。
dynamic _dig(dynamic root, List<String> path) {
  dynamic cur = root;
  for (final k in path) {
    if (cur is Map) {
      cur = cur[k];
    } else {
      return null;
    }
  }
  return cur;
}

String _brief(Object e) {
  final s = '$e';
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}
