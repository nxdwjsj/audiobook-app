import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/drive_item.dart';
import 'cloud_drive_service.dart';
import 'storage_service.dart';

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
      throw Exception('Cookie 无效或已过期');
    }
  }

  @override
  Future<void> logout() async {
    _cookie = null;
    await _storage.saveQuarkCookie('');
    _stokenCache.clear();
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

  DriveItem _fromQuarkShareFile(Map<String, dynamic> f, {String path = ''}) {
    final isDir = f['dir'] == true;
    final name = f['file_name']?.toString() ?? '';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    return DriveItem(
      fileId: f['fid']?.toString() ?? '',
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

  /// 递归解析分享：返回分享内**全部**音频文件（含子目录），供全网搜书用。
  /// 目录遍历限 3 并发，避免大分享串行过慢。
  Future<ShareParseResult> parseShareLinkRecursive(
    String shareUrl, {
    String? pwd,
    int maxDepth = 4,
  }) async {
    final pwdId = extractPwdId(shareUrl);
    if (pwdId.isEmpty) {
      throw Exception('无法从链接中提取分享码');
    }
    final stoken = await _getShareToken(pwdId, pwd);

    final items = <DriveItem>[];
    String? shareTitle;
    String? firstDirName;

    Future<void> collect(
      List<Map<String, dynamic>> entries,
      String parentPath,
      int depth,
      List<(String, String, int)> queue,
    ) async {
      for (final e in entries) {
        final name = e['file_name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final childPath = parentPath.isEmpty ? name : '$parentPath/$name';
        if (e['dir'] == true) {
          if (depth < maxDepth) queue.add((e['fid']?.toString() ?? '0', childPath, depth + 1));
        } else {
          items.add(_fromQuarkShareFile(e, path: childPath));
        }
      }
    }

    final (rootEntries, rootTitle) = await _listShareDir(pwdId, stoken, '0');
    shareTitle = rootTitle;
    for (final e in rootEntries) {
      if (e['dir'] == true) {
        firstDirName ??= e['file_name']?.toString();
      }
    }
    final queue = <(String, String, int)>[];
    await collect(rootEntries, '', 1, queue);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (fid, path, depth) = queue.removeLast();
        final (entries, _) = await _listShareDir(pwdId, stoken, fid);
        await collect(entries, path, depth, queue);
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));

    return ShareParseResult(
      items: items,
      folderName: firstDirName ?? shareTitle ?? '分享资源',
    );
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

  @override
  Future<ResolvedStream> getShareAudioStreamUrl(String shareUrl, String fileId) async {
    // Quark share files must be saved into the user's own drive before
    // they can be streamed. This is a provider limitation.
    throw UnsupportedError(
      '夸克分享链接中的文件需先保存到自己的网盘后才能播放，'
      '请先转存再从"我的网盘"中播放',
    );
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
