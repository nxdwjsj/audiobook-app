import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/drive_item.dart';
import 'cloud_drive_service.dart';
import 'storage_service.dart';

/// 转存结果：摊平的音频列表 + 顶层目录信息（目录名 / 转存后的新 fid）。
/// 书架据此记录「这本书存在网盘的哪个位置」，长按可直接跳进网盘。
class SaveShareResult {
  final List<DriveItem> audioFiles;
  final String? savedDirFid;
  final String? savedDirName;

  const SaveShareResult(this.audioFiles, {this.savedDirFid, this.savedDirName});
}

/// Quark (夸克) cloud drive service.
///
/// Uses reversed-engineered PC-client API endpoints (drive-pc.quark.cn).
/// Authentication is via Cookie (user pastes browser Cookie).
///
/// Key endpoints (all under https://drive-pc.quark.cn/1/clouddrive):
/// - File list: GET  /file/sort (query params: pdir_fid, _page, _size, ...)
/// - Share token: POST /share/sharepage/token (JSON body)
/// - Share detail: GET /share/sharepage/detail (query params)
/// - Download URL: POST /file/download (JSON body)
/// - Account info: GET https://pan.quark.cn/account/info
class QuarkDriveService extends ChangeNotifier implements CloudDriveService {
  /// PC client API base. NOTE: pan.quark.cn serves the web frontend and
  /// rejects these API calls with HTTP 405 (method not allowed).
  static const String _apiBase = 'https://drive-pc.quark.cn';

  static const Map<String, String> _browserHeaders = {
    // MUST match the Quark PC client UA: the download CDN
    // (dl-pc-sz.pds.quark.cn) validates the User-Agent on OSS-signed URLs.
    // A plain Chrome UA gets HTTP 403.
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) quark-cloud-drive/3.14.2 Chrome/112.0.5615.165 '
        'Electron/24.1.3.8 Safari/537.36 Channel/pckk_other_ch',
    'Referer': 'https://pan.quark.cn/',
  };

  /// Headers for the download CDN (dl-pc-zb.drive.quark.cn).
  /// The CDN enforces Cookie precondition: requests without the login
  /// Cookie are rejected with 412. UA/Referer are irrelevant.
  Map<String, String> get _cdnHeaders =>
      {'Cookie': _cookie ?? ''};

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: _browserHeaders,
    // Accept any status code (e.g. 405/500) so we can read the response
    // body and log it for debugging instead of throwing DioException.
    validateStatus: (status) => status != null && status >= 200 && status < 600,
  ));

  final StorageService _storage;
  String? _cookie;
  AuthStatus _authStatus = AuthStatus.unauthenticated;

  /// share pwd_id -> stoken (obtained when parsing a share link).
  final Map<String, String> _stokenCache = {};

  QuarkDriveService(this._storage);

  @override
  DriveType get driveType => DriveType.quark;

  @override
  AuthStatus get authStatus => _authStatus;

  @override
  Future<void> init() async {
    _cookie = _storage.getQuarkCookie();
    if (_cookie != null && _cookie!.isNotEmpty) {
      _authStatus = AuthStatus.authenticated;
    }
    notifyListeners();
  }

  @override
  Future<bool> login() async {
    // Quark requires Cookie pasting; login() just returns true
    // to indicate the UI should show the Cookie input field.
    return true;
  }

  /// Set the Cookie manually (user pasted from browser).
  ///
  /// Validates against the account API BEFORE persisting, so an invalid
  /// cookie is never saved (otherwise the next launch would wrongly show
  /// "authenticated"). Throws on failure so the UI can report the error.
  Future<void> setCookie(String cookie) async {
    final trimmed = cookie.trim();
    final previous = _cookie;

    if (trimmed.isEmpty) {
      _cookie = null;
      await _storage.saveQuarkCookie('');
      _authStatus = AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }

    _cookie = trimmed;
    try {
      await getAccountInfo();
      await _storage.saveQuarkCookie(trimmed); // persist only after success
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
    } catch (e) {
      // Restore the previous state so a typo cannot log the user out.
      _cookie = previous;
      _authStatus = (previous != null && previous.isNotEmpty)
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      notifyListeners();
      // 连不上网时也会走到这里，别一律说成 Cookie 无效（用户会一直换 Cookie）
      if (e is DioException && e.type != DioExceptionType.badResponse) {
        throw Exception('网络请求失败，请检查网络后重试');
      }
      throw Exception('Cookie 无效或已过期');
    }
  }

  @override
  Future<void> logout() async {
    _cookie = null;
    await _storage.saveQuarkCookie('');
    _stokenCache.clear();
    // 转存相关缓存都绑着上一个账号的 fid，必须一起清掉
    _savedShareAudio.clear();
    _savingShares.clear();
    _shareInboxFid = null;
    _authStatus = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Map<String, String> get _authHeaders => {
        if (_cookie != null) 'Cookie': _cookie!,
      };

  // ------------------------------------------------------------------
  // Request logging + response checking helpers
  // ------------------------------------------------------------------

  /// Log a request/response pair for debugging API issues.
  /// 注意：不打印 headers/body，避免登录 Cookie 泄露到 logcat。
  void _logHttp(String tag, Response response) {
    final req = response.requestOptions;
    debugPrint('[$tag] Quark API: ${req.method} ${req.uri} '
        '→ ${response.statusCode}');
  }

  /// Throws a descriptive [Exception] when the API response is not usable.
  /// Covers: non-JSON body, HTTP-level errors (405/500...), and
  /// business-level errors (code != 0).
  Never _throwApiError(String tag, Response response) {
    _logHttp(tag, response);
    final status = response.statusCode ?? -1;
    final data = response.data;
    if (data is! Map) {
      throw Exception('[$tag] HTTP $status，响应非 JSON: '
          '${data.toString().substring(0, data.toString().length.clamp(0, 300))}');
    }
    final code = data['code'];
    if (code != 0) {
      _handleAuthError(code is int ? code : int.tryParse(code.toString()) ?? -1);
      throw Exception('[$tag] code=$code ${data['message'] ?? ''}');
    }
    throw Exception('[$tag] HTTP $status 未知错误');
  }

  void _handleAuthError(int code) {
    if (code == 401 || code == 403) {
      _authStatus = AuthStatus.expired;
      notifyListeners();
    }
  }

  /// Extract pwd_id from a share URL like
  /// https://pan.quark.cn/s/xxxxx#/list/share or .../s/xxxxx.
  String extractPwdId(String shareUrl) {
    final uri = Uri.parse(shareUrl);
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] == 's' && i + 1 < segments.length) {
        return segments[i + 1];
      }
    }
    return segments.isNotEmpty ? segments.last : '';
  }

  // ------------------------------------------------------------------
  // File listing (own drive)
  // ------------------------------------------------------------------

  @override
  Future<List<DriveItem>> listFolder({String path = '/', String? dirFileId}) async {
    if (_cookie == null) throw StateError('Not authenticated');

    // Quark navigates by fid ("0" for root). Prefer the fid when the
    // caller knows it; otherwise resolve the path by traversal.
    final pdirFid = dirFileId ?? await _resolvePathToFid(path);

    final items = <DriveItem>[];
    var page = 1;
    const size = 100;
    // Loop until the last page; guards against share loops with a max cap.
    while (true) {
      final response = await _dio.get(
        '$_apiBase/1/clouddrive/file/sort',
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'pdir_fid': pdirFid,
          '_page': page,
          '_size': '$size',
          '_fetch_total': '1',
          '_fetch_sub_dirs': '0',
          '_sort': 'file_type:asc,file_name:asc',
          '_fetch_full_path': '0',
          'fetch_all_file': '1',
        },
        options: Options(headers: _authHeaders),
      );

      final data = response.data;
      if (data is! Map || data['code'] != 0) {
        _throwApiError('file/sort', response);
      }
      _logHttp('file/sort p$page', response);

      final list = (data['data']?['list'] as List<dynamic>? ?? []);
      items.addAll(list.map((f) => _fromQuarkFile(f as Map<String, dynamic>, path)));
      // NOTE: _total lives in the TOP-LEVEL metadata (not data.metadata).
      final total = (data['metadata']?['_total'] as num?)?.toInt() ?? items.length;
      if (items.length >= total || list.length < size) break;
      page++;
      if (page > 200) break; // safety cap: 20k entries
    }

    return items;
  }

  /// Resolve a path like "/有声书/三体" to its pdir_fid.
  /// For root "/", returns "0".
  Future<String> _resolvePathToFid(String path) async {
    if (path == '/' || path.isEmpty) return '0';

    // Traverse path segments
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    String currentFid = '0';
    String currentPath = '';

    for (final segment in segments) {
      currentPath = currentPath == '' ? '/$segment' : '$currentPath/$segment';
      final response = await _dio.get(
        '$_apiBase/1/clouddrive/file/sort',
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'pdir_fid': currentFid,
          '_page': '1',
          '_size': '100',
          '_fetch_total': '1',
          '_fetch_sub_dirs': '0',
          '_sort': 'file_type:asc,file_name:asc',
          'fetch_all_file': '1',
        },
        options: Options(headers: _authHeaders),
      );

      final data = response.data;
      if (data is! Map || data['code'] != 0) {
        _throwApiError('resolvePath', response);
      }

      final list = (data['data']?['list'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final match = list.where(
        (f) => f['file_name'] == segment && f['dir'] == true,
      );
      if (match.isEmpty) {
        throw Exception('Folder not found: $segment');
      }
      currentFid = match.first['fid']?.toString() ?? '0';
    }

    return currentFid;
  }

  DriveItem _fromQuarkFile(Map<String, dynamic> f, String parentPath) {
    final isDir = f['dir'] == true;
    final name = f['file_name']?.toString() ?? '';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    return DriveItem(
      fileId: f['fid']?.toString() ?? '',
      name: name,
      path: '$parentPath/$name',
      isDir: isDir,
      size: (f['size'] as num?)?.toInt() ?? 0,
      extension: ext,
      parentPath: parentPath,
      fileCount: (f['include_items'] as num?)?.toInt() ?? 0,
    );
  }

  /// 在网盘全库中搜索文件/文件夹（搜索页用）。
  /// 返回路径基于 dir_path，文件夹可直达、音频可进所在目录。
  Future<List<DriveItem>> searchFiles(String keyword,
      {int limit = 50}) async {
    if (_cookie == null) throw StateError('Not authenticated');

    final response = await _dio.get(
      '$_apiBase/1/clouddrive/file/search',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'q': keyword,
        '_page': 1,
        '_size': '$limit',
        '_fetch_total': '1',
        '_sort': 'file_type:asc,file_name:asc',
      },
      options: Options(headers: _authHeaders),
    );

    final data = response.data;
    if (data is! Map || data['code'] != 0) {
      _throwApiError('file/search', response);
    }
    _logHttp('file/search', response);

    final list = (data['data']?['list'] as List<dynamic>? ?? []);
    return list.map((f) {
      final m = f as Map<String, dynamic>;
      final isDir = m['dir'] == true;
      final name = m['file_name']?.toString() ?? '';
      final dirPath = m['dir_path']?.toString() ?? '/';
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
      return DriveItem(
        fileId: m['fid']?.toString() ?? '',
        name: name,
        path: isDir ? dirPath : '$dirPath/$name',
        isDir: isDir,
        size: (m['size'] as num?)?.toInt() ?? 0,
        extension: ext,
        parentPath: dirPath,
      );
    }).toList();
  }

  // ------------------------------------------------------------------
  // Share link parsing (Scheme B)
  // ------------------------------------------------------------------

  /// Obtain (and cache) the stoken for a share link.
  /// Required before calling sharepage/detail.
  Future<String> _getShareToken(String pwdId, String? pwd) async {
    final cached = _stokenCache[pwdId];
    if (cached != null) return cached;

    final response = await _dio.post(
      '$_apiBase/1/clouddrive/share/sharepage/token',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc', '_t': _nowMs()},
      data: {
        'pwd_id': pwdId,
        'passcode': pwd ?? '',
      },
      options: Options(headers: _authHeaders),
    );

    final data = response.data;
    if (data is! Map || data['code'] != 0) {
      _throwApiError('sharepage/token', response);
    }
    _logHttp('sharepage/token', response);
    final stoken = data['data']?['stoken']?.toString();
    if (stoken == null || stoken.isEmpty) {
      throw Exception('获取分享令牌失败: stoken 为空');
    }
    _stokenCache[pwdId] = stoken;
    return stoken;
  }

  @override
  Future<ShareParseResult> parseShareLink(String shareUrl, {String? pwd}) async {
    final pwdId = extractPwdId(shareUrl);
    if (pwdId.isEmpty) {
      throw Exception('无法从链接中提取分享码');
    }

    final stoken = await _getShareToken(pwdId, pwd);

    final detailResp = await _dio.get(
      '$_apiBase/1/clouddrive/share/sharepage/detail',
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'pwd_id': pwdId,
        'stoken': stoken,
        'pdir_fid': '0',
        'force': '1',
        '_page': '1',
        '_size': '100',
        '_fetch_banner': '0',
        '_fetch_share': '0',
        '_fetch_total': '1',
        '_sort': 'file_type:asc,file_name:asc',
        'ver': '2',
      },
      options: Options(headers: _authHeaders),
    );

    final detail = detailResp.data;
    if (detail is! Map || detail['code'] != 0) {
      _throwApiError('sharepage/detail', detailResp);
    }
    _logHttp('sharepage/detail', detailResp);

    final title = detail['data']?['title']?.toString() ?? '分享资源';
    final fileList =
        (detail['data']?['list'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();

    final items = fileList.map(_fromQuarkShareFile).toList();

    return ShareParseResult(items: items, folderName: title);
  }

  DriveItem _fromQuarkShareFile(
    Map<String, dynamic> f, {
    String path = '',
    String? fileIdOverride,
  }) {
    final isDir = f['dir'] == true;
    final name = f['file_name']?.toString() ?? '';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    return DriveItem(
      fileId: fileIdOverride ?? f['fid']?.toString() ?? '',
      name: name,
      path: path.isEmpty ? name : path,
      isDir: isDir,
      size: (f['size'] as num?)?.toInt() ?? 0,
      extension: ext,
      parentPath: '',
    );
  }

  /// 列出一个分享目录（自动翻页），返回条目 + 分享标题。
  Future<(List<Map<String, dynamic>>, String?)> _listShareDir(
    String pwdId,
    String stoken,
    String fid,
  ) async {
    final out = <Map<String, dynamic>>[];
    String? title;
    var page = 1;
    while (true) {
      final resp = await _dio.get(
        '$_apiBase/1/clouddrive/share/sharepage/detail',
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'pwd_id': pwdId,
          'stoken': stoken,
          'pdir_fid': fid,
          'force': '0',
          '_page': '$page',
          '_size': '100',
          '_fetch_banner': '0',
          '_fetch_share': '0',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,file_name:asc',
          'ver': '2',
        },
        options: Options(headers: _authHeaders),
      );
      final data = resp.data;
      if (data is! Map || data['code'] != 0) {
        _throwApiError('sharepage/detail', resp);
      }
      title ??= data['data']?['title']?.toString();
      final list = (data['data']?['list'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      out.addAll(list);
      if (list.length < 100) break;
      page++;
      if (page > 50) break; // 单目录上限 5000 条
    }
    return (out, title);
  }

  /// 递归解析分享，并**按顶层分组成「书」**：顶层每个目录算一本，
  /// 顶层散落的音频合并成一组。
  ///
  /// 合集类分享（一个链接塞几十本书）因此不会被混成一本，也便于只转存
  /// 用户真正想要的那一本。深度保留 4，性能靠目录/音频上限与并发控制。
  Future<(List<ShareGroup>, String?)> parseShareGroups(
    String shareUrl, {
    String? pwd,
    int maxDepth = 4,
    int maxDirsPerGroup = 60,
    int maxAudioPerGroup = 1200,
    int concurrency = 4,
  }) async {
    final pwdId = extractPwdId(shareUrl);
    if (pwdId.isEmpty) {
      throw Exception('无法从链接中提取分享码');
    }
    final stoken = await _getShareToken(pwdId, pwd);
    final (rootEntries, shareTitle) = await _listShareDir(pwdId, stoken, '0');

    // 分组：目录各成一组；顶层散落的音频文件合并成一组
    final groups = <ShareGroup>[];
    final loose = <Map<String, dynamic>>[];
    for (final e in rootEntries) {
      final name = e['file_name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (e['dir'] == true) {
        groups.add(ShareGroup(title: name, entries: [e]));
      } else if (DriveItem.isAudioFile(name)) {
        loose.add(e);
      }
    }
    if (loose.isNotEmpty) {
      groups.add(ShareGroup(title: shareTitle ?? '分享资源', entries: loose));
    }
    if (groups.isEmpty) throw Exception('分享内没有可播放的音频');

    final audios = List.generate(groups.length, (_) => <DriveItem>[]);
    final dirCounts = List.filled(groups.length, 0);
    // 待遍历队列：(组号, 目录 fid, 相对路径, 深度)
    final pending = <(int, String, String, int)>[];
    for (var gi = 0; gi < groups.length; gi++) {
      for (final e in groups[gi].entries) {
        final name = e['file_name']?.toString() ?? '';
        if (e['dir'] == true) {
          final fid = e['fid']?.toString() ?? '';
          if (fid.isEmpty) continue;
          dirCounts[gi]++;
          pending.add((gi, fid, name, 2));
        } else {
          audios[gi].add(_fromQuarkShareFile(e, path: name));
        }
      }
    }

    // 所有组共用一组 worker：目录多的分享也不用一个个排队等
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final (gi, fid, path, depth) = pending.removeLast();
        if (audios[gi].length >= maxAudioPerGroup) continue;
        if (dirCounts[gi] > maxDirsPerGroup) continue;
        final (entries, _) = await _listShareDir(pwdId, stoken, fid);
        for (final e in entries) {
          if (audios[gi].length >= maxAudioPerGroup) break;
          final name = e['file_name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final childPath = '$path/$name';
          if (e['dir'] == true) {
            if (depth >= maxDepth || dirCounts[gi] >= maxDirsPerGroup) continue;
            final cfid = e['fid']?.toString() ?? '';
            if (cfid.isEmpty) continue;
            dirCounts[gi]++;
            pending.add((gi, cfid, childPath, depth + 1));
          } else if (DriveItem.isAudioFile(name)) {
            audios[gi].add(_fromQuarkShareFile(e, path: childPath));
          }
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    for (var i = 0; i < groups.length; i++) {
      groups[i].audioItems = audios[i];
    }
    // 图片 / 文档类目录解析不出音频，直接丢掉
    final usable = groups.where((g) => g.audioItems.isNotEmpty).toList();
    if (usable.isEmpty) throw Exception('分享内没有可直接播放的音频');
    return (usable, shareTitle);
  }

  // ------------------------------------------------------------------
  // Share → save into own drive
  //
  // 夸克分享里的文件**没有**直链接口（share/sharepage/download 已 404），
  // 必须先转存到自己的网盘（share/sharepage/save，异步任务）才能播放。
  // ------------------------------------------------------------------

  /// 转存后的音频缓存：缓存键 -> 自己网盘里的音频列表。
  final Map<String, List<DriveItem>> _savedShareAudio = {};

  /// 转存结果缓存（含目录 fid）。与 [_savedShareAudio] 分开存，
  /// 旧调用点（getShareAudioStreamUrl 按 fid 找音频）继续用后者。
  final Map<String, SaveShareResult> _savedShareResults = {};

  /// 正在进行的转存任务：缓存键 -> Future。
  /// 同一个分享被连点两次时复用同一个任务，避免转存出两份重复文件。
  final Map<String, Future<SaveShareResult>> _savingShares = {};

  String? _shareInboxFid;

  /// 把分享转存到自己的网盘，返回转存后可播放的音频列表
  /// （fileId 已是自己网盘的 fid，可直接走 file/download），
  /// 以及这本书顶层目录（如有）转存后的 fid —— 书架用它记录网盘存放位置。
  ///
  /// [entries] 只转存指定的顶层条目（即分享里的某一本书）；为空则整个分享。
  /// [toDirFid] 指定保存目录；为空时用「来自：分享」目录（没有就放根目录）。
  Future<SaveShareResult> saveShareToMyDrive(
    String shareUrl, {
    String? pwd,
    int maxDepth = 4,
    List<Map<String, dynamic>>? entries,
    String? toDirFid,
  }) {
    final pwdId = extractPwdId(shareUrl);
    final key = _shareKey(pwdId, entries, toDirFid);
    // 空结果也要缓存：否则「转存成功但没找到音频」的分享会被反复转存，
    // 在网盘里堆出重复文件。
    final cached = _savedShareResults[key];
    if (cached != null) return Future.value(cached);
    final inFlight = _savingShares[key];
    if (inFlight != null) return inFlight;

    final future = _doSaveShare(pwdId, pwd, maxDepth, entries, toDirFid);
    _savingShares[key] = future;
    // 另起一条链挂空 handler：任务失败时不产生未捕获的异步异常，
    // 同时保证无论成败都会把 in-flight 记录清掉。
    future.then<void>((_) {}, onError: (_) {}).whenComplete(
          () => _savingShares.remove(key),
        );
    return future;
  }

  /// 转存缓存键：同一分享的不同书、不同保存目录要分开缓存。
  String _shareKey(
    String pwdId,
    List<Map<String, dynamic>>? entries,
    String? toDirFid,
  ) {
    if (entries == null) return '$pwdId|all|${toDirFid ?? ''}';
    final fids = entries.map((e) => e['fid']?.toString() ?? '').join('-');
    return '$pwdId|$fids|${toDirFid ?? ''}';
  }

  Future<SaveShareResult> _doSaveShare(
    String pwdId,
    String? pwd,
    int maxDepth,
    List<Map<String, dynamic>>? onlyEntries,
    String? toDirFid,
  ) async {
    if (_cookie == null) throw StateError('Not authenticated');
    if (pwdId.isEmpty) throw Exception('无法从链接中提取分享码');

    final stoken = await _getShareToken(pwdId, pwd);
    final entries =
        onlyEntries ?? (await _listShareDir(pwdId, stoken, '0')).$1;
    if (entries.isEmpty) throw Exception('分享内没有文件');

    final fidList = <String>[];
    final tokenList = <String>[];
    final metas = <Map<String, dynamic>>[];
    for (final e in entries) {
      final fid = e['fid']?.toString() ?? '';
      if (fid.isEmpty) continue;
      fidList.add(fid);
      tokenList.add((e['share_fid_token'] ?? e['fid_token'] ?? '').toString());
      metas.add(e);
    }
    if (fidList.isEmpty) throw Exception('分享内没有可转存的文件');

    final toDir = toDirFid ?? await _resolveShareInboxFid();
    final resp = await _dio.post(
      '$_apiBase/1/clouddrive/share/sharepage/save',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
      data: {
        'fid_list': fidList,
        'fid_token_list': tokenList,
        'to_pdir_fid': toDir,
        'pwd_id': pwdId,
        'stoken': stoken,
        'pdir_fid': '0',
        'scene': 'link',
        'exclude_fids': <String>[],
      },
      options: Options(headers: _authHeaders),
    );
    final data = resp.data;
    if (data is! Map || data['code'] != 0) {
      _throwApiError('sharepage/save', resp);
    }
    _logHttp('sharepage/save', resp);
    final taskId = data['data']?['task_id']?.toString() ?? '';
    if (taskId.isEmpty) throw Exception('转存任务创建失败');

    var savedFids = await _awaitTask(taskId);
    // 夸克在任务刚 done 时偶尔还没带上 save_as_top_fids（转存目录时尤其常见），
    // 再等两轮；仍拿不到就在目标目录里按名字回查，
    // 避免「其实已经转存成功，却弹数量异常」。
    for (var retry = 0;
        retry < 2 && savedFids.length != metas.length;
        retry++) {
      await Future.delayed(const Duration(milliseconds: 1200));
      savedFids = await _awaitTask(taskId);
    }
    if (savedFids.length != metas.length) {
      savedFids = await _locateSavedEntries(toDir, metas);
    }
    if (savedFids.length != metas.length) {
      // 数量对不上就没法保证「下标 ↔ 文件名」一一对应，
      // 与其静默错配章节（点 A 播 B），不如让用户重试。
      throw Exception(
          '转存结果数量异常（${savedFids.length}/${metas.length}），请稍后重试');
    }

    // savedFids 与提交顺序一一对应：目录递归列出，文件直接采用新 fid。
    final out = <DriveItem>[];
    final dirTasks = <(String, String)>[]; // (转存后的 fid, 目录名)
    for (var i = 0; i < metas.length; i++) {
      final e = metas[i];
      final name = e['file_name']?.toString() ?? '';
      if (e['dir'] == true) {
        dirTasks.add((savedFids[i], name));
      } else {
        final item = _fromQuarkShareFile(e, path: name,
            fileIdOverride: savedFids[i]);
        if (item.isAudio) out.add(item);
      }
    }
    // 顶层目录并发遍历（目录内部仍串行），避免几十个目录一个个排队等
    final buckets = List.generate(dirTasks.length, (_) => <DriveItem>[]);
    var cursor = 0;
    Future<void> walker() async {
      while (cursor < dirTasks.length) {
        final idx = cursor++;
        final (fid, name) = dirTasks[idx];
        await _walkOwnFolder(fid, name, 1, maxDepth, buckets[idx]);
      }
    }

    final workers = dirTasks.length < 4 ? dirTasks.length : 4;
    await Future.wait(List.generate(workers, (_) => walker()));
    for (final b in buckets) {
      out.addAll(b);
    }
    // 这本书只有一个顶层目录时，记录该目录转存后的 fid 和名字，
    // 书架即可显示「存在网盘哪里」并直接跳进去。
    final String? savedDirFid = dirTasks.length == 1 ? dirTasks[0].$1 : null;
    final String? savedDirName = dirTasks.length == 1 ? dirTasks[0].$2 : null;
    final result =
        SaveShareResult(out, savedDirFid: savedDirFid, savedDirName: savedDirName);
    final key = _shareKey(pwdId, onlyEntries, toDirFid);
    _savedShareAudio[key] = out;
    _savedShareResults[key] = result;
    return result;
  }

  /// 轮询转存任务直到完成，返回转存后顶层条目的新 fid。
  /// 大分享的任务可能跑得较久：前 10 次 0.5s 快探，之后 1s，总窗口约 95 秒。
  Future<List<String>> _awaitTask(String taskId) async {
    for (var i = 0; i < 100; i++) {
      await Future.delayed(Duration(milliseconds: i < 10 ? 500 : 1000));
      final resp = await _dio.get(
        '$_apiBase/1/clouddrive/task',
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'task_id': taskId,
          'retry_index': '$i',
        },
        options: Options(headers: _authHeaders),
      );
      final data = resp.data;
      if (data is! Map || data['code'] != 0) {
        _throwApiError('task', resp);
      }
      final status = (data['data']?['status'] as num?)?.toInt();
      if (status == 2) {
        _logHttp('task done', resp);
        return (data['data']?['save_as_top_fids'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
      }
      if (status == 3) {
        throw Exception('转存失败：${data['data']?['message'] ?? '未知原因'}');
      }
    }
    throw Exception('转存超时（任务可能仍在后台进行），请稍后在网盘中确认');
  }

  /// 转存任务给的 save_as_top_fids 不可靠时，按名字在目标目录里回查新 fid。
  ///
  /// 夸克对「转存目录」有时不返回 save_as_top_fids，与其让用户重试，
  /// 不如直接列一次目标目录，按条目名 + 类型对上。
  Future<List<String>> _locateSavedEntries(
    String toDirFid,
    List<Map<String, dynamic>> metas,
  ) async {
    final List<DriveItem> items;
    try {
      items = await listFolder(
        dirFileId: (toDirFid.isEmpty || toDirFid == '0') ? null : toDirFid,
      );
    } catch (e) {
      debugPrint('[quark] 回查转存结果失败: $e');
      return const [];
    }
    final byName = <String, List<DriveItem>>{};
    for (final it in items) {
      byName.putIfAbsent(it.name, () => []).add(it);
    }
    final out = <String>[];
    final used = <String, int>{};
    for (final e in metas) {
      final name = e['file_name']?.toString() ?? '';
      final wantDir = e['dir'] == true;
      final candidates =
          byName[name]?.where((i) => i.isDir == wantDir).toList() ?? const [];
      final idx = used[name] ?? 0;
      if (idx >= candidates.length) return const [];
      used[name] = idx + 1;
      out.add(candidates[idx].fileId);
    }
    return out;
  }

  /// 转存目标目录：优先「来自：分享」，没有就放根目录。
  Future<String> _resolveShareInboxFid() async {
    if (_shareInboxFid != null) return _shareInboxFid!;
    try {
      final roots = await listFolder(path: '/');
      for (final e in roots) {
        if (e.isDir && e.name.replaceAll('：', ':') == '来自:分享') {
          return _shareInboxFid = e.fileId;
        }
      }
      // 确实没有这个目录，缓存根目录，省掉后续每次转存的列目录请求
      return _shareInboxFid = '0';
    } catch (e) {
      // 查询失败 ≠ 没有这个目录：不写缓存，下次再查
      debugPrint('[quark] 查找「来自：分享」目录失败: $e');
      return '0';
    }
  }

  /// 在**自己网盘**里递归收集音频（fid 均为网盘 fid）。
  Future<void> _walkOwnFolder(
    String fid,
    String parentPath,
    int depth,
    int maxDepth,
    List<DriveItem> out,
  ) async {
    if (depth > maxDepth) return;
    final children = await listFolder(path: parentPath, dirFileId: fid);
    for (final c in children) {
      final path = parentPath.isEmpty ? c.name : '$parentPath/${c.name}';
      if (c.isDir) {
        await _walkOwnFolder(c.fileId, path, depth + 1, maxDepth, out);
      } else if (c.isAudio) {
        out.add(DriveItem(
          fileId: c.fileId,
          name: c.name,
          path: path,
          isDir: false,
          size: c.size,
          extension: c.extension,
          parentPath: parentPath,
        ));
      }
    }
  }

  // ------------------------------------------------------------------
  // Audio stream URLs
  // ------------------------------------------------------------------

  @override
  Future<ResolvedStream> getAudioStreamUrl(String fileId) async {
    if (_cookie == null) throw StateError('Not authenticated');

    final response = await _dio.post(
      '$_apiBase/1/clouddrive/file/download',
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
      data: {
        'fids': [fileId],
      },
      options: Options(headers: _authHeaders),
    );

    final data = response.data;
    if (data is! Map || data['code'] != 0) {
      _throwApiError('file/download', response);
    }
    _logHttp('file/download', response);

    // Response shape: {"code":0,"data":[{"download_url":"https://..."}]}
    final list = data['data'];
    if (list is List && list.isNotEmpty) {
      final url = (list[0] as Map<String, dynamic>)['download_url']?.toString();
      if (url == null || url.isEmpty) {
        throw Exception('未返回下载链接');
      }
      // CDN headers: ONLY the UA. The OSS bucket (dl-pc-sz.pds.quark.cn)
      // has anti-hotlinking: sending Referer/Cookie to it returns 403.
      return ResolvedStream(url, headers: _cdnHeaders);
    }
    if (list is Map && list['download_url'] != null) {
      return ResolvedStream(list['download_url'].toString(), headers: _cdnHeaders);
    }
    throw Exception('未返回下载链接');
  }

  /// 分享文件不能直链播放：必须先转存到自己的网盘（首次调用会比较慢），
  /// 再用转存后的 fid 走 file/download。
  @override
  Future<ResolvedStream> getShareAudioStreamUrl(
    String shareUrl,
    String fileId, {
    String? filename,
  }) async {
    if (_cookie == null) throw StateError('Not authenticated');
    final pwdId = extractPwdId(shareUrl);
    if (pwdId.isEmpty) throw Exception('无法从链接中提取分享码');

    final audio = _savedShareAudio[_shareKey(pwdId, null, null)] ??
        (await saveShareToMyDrive(shareUrl)).audioFiles;
    if (audio.isEmpty) throw Exception('该分享里没有可直接播放的音频文件');

    DriveItem? target;
    for (final a in audio) {
      if (a.fileId == fileId) {
        target = a;
        break;
      }
    }
    // 老数据：章节里存的还是分享内的 fid，按文件名找回转存后的 fid。
    if (target == null && filename != null && filename.isNotEmpty) {
      for (final a in audio) {
        if (a.name == filename) {
          target = a;
          break;
        }
      }
    }
    if (target == null) {
      throw Exception('未在转存的文件中匹配到该章节，请重新从「全网搜书」加入书架');
    }
    return getAudioStreamUrl(target.fileId);
  }

  @override
  Future<Map<String, dynamic>> getAccountInfo() async {
    if (_cookie == null) throw StateError('Not authenticated');

    final response = await _dio.get(
      'https://pan.quark.cn/account/info',
      queryParameters: {'fr': 'pc', 'platform': 'pc'},
      options: Options(headers: _authHeaders),
    );

    final data = response.data;
    if (data is! Map || data['data'] == null) {
      _throwApiError('account/info', response);
    }
    _logHttp('account/info', response);
    return Map<String, dynamic>.from(data);
  }

  String _nowMs() => (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
}

/// 分享里的「一本书」：顶层的一个目录，或顶层散落的若干音频文件。
///
/// 有了分组，合集类分享（一个链接塞几十本书）就能在搜索结果里拆成多本，
/// 转存时也只提交这一本的顶层 fid，不会把整个合集搬进网盘。
class ShareGroup {
  /// 书名：顶层目录名，或分享标题（散落音频那一组）
  final String title;

  /// 该组的顶层原始条目。转存时只提交这些（取 fid 与 share_fid_token）。
  final List<Map<String, dynamic>> entries;

  /// 递归收集到的音频（fileId 是分享内的 fid，转存后会被替换）
  List<DriveItem> audioItems;

  ShareGroup({
    required this.title,
    required this.entries,
    this.audioItems = const [],
  });

  int get audioBytes => audioItems.fold(0, (s, i) => s + i.size);
}
