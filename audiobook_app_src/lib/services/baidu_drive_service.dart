import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/drive_item.dart';
import 'cloud_drive_service.dart';
import 'storage_service.dart';

/// Baidu Netdisk cloud drive service.
///
/// Uses Baidu's official Open Platform API for the user's own drive:
/// - OAuth2 implicit grant for authorization
/// - /rest/2.0/xpan/file for file listing
/// - /rest/2.0/xpan/multimedia for file metadata (dlink)
///
/// Share-link parsing uses the web share endpoints, which require a
/// logged-in browser Cookie (BDUSS). The user pastes that Cookie in the
/// drive login page.
class BaiduDriveService extends ChangeNotifier implements CloudDriveService {
  static const String _apiBase = 'https://pan.baidu.com/rest/2.0/xpan';
  static const String _oauthBase = 'https://openapi.baidu.com/oauth/2.0';
  static const String _webBase = 'https://pan.baidu.com';

  // Baidu Pan official demo app credentials (for personal learning use).
  // This legacy demo AppKey has been revoked by Baidu. Users must register
  // their own app at https://pan.baidu.com/union and paste the AppKey (API Key)
  // in the drive login page.
  static const String _defaultClientId = 'iYCeC9g08h5vuP9UqvPHKKSVrAz';
  static const String _redirectUri = 'oob';

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://pan.baidu.com/',
  };

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: _browserHeaders,
  ));

  final StorageService _storage;
  String? _accessToken;
  String? _cookie;
  AuthStatus _authStatus = AuthStatus.unauthenticated;

  BaiduDriveService(this._storage);

  /// The AppKey (API Key) used to build the OAuth authorize URL.
  /// Falls back to the (revoked) demo key when the user has not set one.
  String get clientId {
    final saved = _storage.getBaiduAppKey();
    if (saved != null && saved.isNotEmpty) return saved;
    return _defaultClientId;
  }

  /// Whether the user has configured their own AppKey.
  bool get hasCustomAppKey {
    final saved = _storage.getBaiduAppKey();
    return saved != null && saved.isNotEmpty;
  }

  /// Save a user-provided AppKey (API Key) for OAuth authorization.
  Future<void> setAppKey(String appKey) async {
    await _storage.saveBaiduAppKey(appKey.trim());
    notifyListeners();
  }

  @override
  DriveType get driveType => DriveType.baidu;

  @override
  AuthStatus get authStatus => _authStatus;

  @override
  Future<void> init() async {
    _accessToken = _storage.getBaiduToken();
    _cookie = _storage.getBaiduCookie();
    if ((_accessToken != null && _accessToken!.isNotEmpty) ||
        (_cookie != null && _cookie!.isNotEmpty)) {
      _authStatus = AuthStatus.authenticated;
    }
    notifyListeners();
  }

  @override
  Future<bool> login() async {
    final authUrl =
        '$_oauthBase/authorize?response_type=token'
        '&client_id=$clientId'
        '&redirect_uri=$_redirectUri'
        '&scope=basic,netdisk';

    final uri = Uri.parse(authUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    // User must paste the access_token manually after authorizing.
    // Returning true indicates the login flow was started.
    return true;
  }

  /// Set the access token manually (user pasted from browser).
  /// Validates the token before persisting/marking as authenticated.
  Future<void> setAccessToken(String token) async {
    final trimmed = token.trim();
    final previous = _accessToken;

    if (trimmed.isEmpty) {
      _accessToken = null;
      await _storage.saveBaiduToken('');
      _authStatus = _cookie != null && _cookie!.isNotEmpty
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }

    _accessToken = trimmed;
    try {
      await getAccountInfo(); // throws when the token is invalid
      await _storage.saveBaiduToken(trimmed); // persist only on success
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
    } catch (e) {
      // Roll back so a bad token is never saved (otherwise the next launch
      // would read it back from storage and wrongly report "authenticated").
      _accessToken = previous;
      _authStatus = (previous != null && previous.isNotEmpty) ||
              (_cookie != null && _cookie!.isNotEmpty)
          ? AuthStatus.authenticated
          : AuthStatus.expired;
      notifyListeners();
      throw Exception('Token 无效或已过期');
    }
  }

  /// Set the web Cookie (BDUSS) manually, needed for share-link parsing.
  Future<void> setCookie(String cookie) async {
    _cookie = cookie.trim();
    await _storage.saveBaiduCookie(_cookie!);
    if (_cookie!.isNotEmpty) {
      _authStatus = AuthStatus.authenticated;
    }
    notifyListeners();
  }

  @override
  Future<void> logout() async {
    _accessToken = null;
    _cookie = null;
    await _storage.saveBaiduToken('');
    await _storage.saveBaiduCookie('');
    _authStatus = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Map<String, String> get _webAuthHeaders => {
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': _cookie!,
      };

  /// Baidu returns errno -6 when the access_token is invalid/expired.
  void _checkErrno(dynamic errno) {
    final code = errno is int ? errno : int.tryParse(errno?.toString() ?? '');
    if (code == -6) {
      _authStatus = AuthStatus.expired;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------
  // File listing (own drive)
  // ------------------------------------------------------------------

  @override
  Future<List<DriveItem>> listFolder({String path = '/', String? dirFileId}) async {
    if (_accessToken == null) throw StateError('Not authenticated');

    // Baidu paginates with start/limit; loop to fetch all entries.
    final items = <DriveItem>[];
    var start = 0;
    const limit = 1000;

    while (true) {
      final response = await _dio.get(
        '$_apiBase/file',
        queryParameters: {
          'method': 'list',
          'dir': path,
          'access_token': _accessToken,
          'order': 'name',
          'desc': 0,
          'start': start,
          'limit': limit,
          'web': 'web',
        },
      );

      final data = response.data;
      if (data['errno'] != 0) {
        _checkErrno(data['errno']);
        throw Exception('Baidu API error: ${data['errno']}');
      }

      final list = data['list'] as List<dynamic>? ?? [];
      items.addAll(list.map((f) => _fromBaiduFile(f, path)));
      if (list.length < limit) break;
      start += limit;
    }

    return items;
  }

  DriveItem _fromBaiduFile(Map<String, dynamic> f, String parentPath) {
    final isDir = f['isdir'] == 1;
    final name = f['server_filename']?.toString() ?? f['filename']?.toString() ?? '';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    return DriveItem(
      fileId: f['fs_id']?.toString() ?? '',
      name: name,
      path: f['path']?.toString() ?? '$parentPath/$name',
      isDir: isDir,
      size: (f['size'] as num?)?.toInt() ?? 0,
      extension: ext,
      parentPath: parentPath,
    );
  }

  // ------------------------------------------------------------------
  // Share link parsing (Scheme B)
  // ------------------------------------------------------------------

  /// Extract the short share key (surl) from a link.
  /// https://pan.baidu.com/s/1AbCdEf -> "AbCdEf" (leading "1" stripped).
  String _extractSurl(String shareUrl) {
    final uri = Uri.parse(shareUrl);
    final segments = uri.pathSegments;
    final idx = segments.indexOf('s');
    var key = idx >= 0 && idx + 1 < segments.length
        ? segments[idx + 1]
        : (segments.isNotEmpty ? segments.last : '');
    if (key.startsWith('1')) key = key.substring(1);
    return key;
  }

  /// Fetch sign/timestamp required by the share endpoints.
  Future<Map<String, String>> _getShareSign(String surl) async {
    final resp = await _dio.get(
      '$_webBase/share/tplconfig',
      queryParameters: {
        'surl': surl,
        'fields': 'sign,timestamp',
        'channel': 'chunlei',
        'web': 1,
        'app_id': 250528,
        'clienttype': 0,
      },
      options: Options(headers: _webAuthHeaders),
    );

    final data = resp.data;
    final sign = data['data']?['sign']?.toString();
    final timestamp = data['data']?['timestamp']?.toString();
    if (sign == null || timestamp == null) {
      throw Exception('获取分享签名失败');
    }
    return {'sign': sign, 'timestamp': timestamp};
  }

  @override
  Future<ShareParseResult> parseShareLink(String shareUrl, {String? pwd}) async {
    if (_cookie == null || _cookie!.isEmpty) {
      throw Exception('解析百度分享链接需要 Cookie（BDUSS），请先在网盘设置中填写');
    }

    final surl = _extractSurl(shareUrl);
    if (surl.isEmpty) {
      throw Exception('无法从链接中提取分享标识');
    }

    final sign = await _getShareSign(surl);

    final resp = await _dio.get(
      '$_webBase/share/wxlist',
      queryParameters: {
        'channel': 'chunlei',
        'version': '2.2.2',
        'clienttype': 0,
        'web': 1,
        'app_id': 250528,
        'shorturl': surl,
        'sign': sign['sign'],
        'timestamp': sign['timestamp'],
        if (pwd != null && pwd.isNotEmpty) 'pwd': pwd,
      },
      options: Options(headers: _webAuthHeaders),
    );

    final data = resp.data;
    if (data['errno'] != 0) {
      final msg = data['errno'] == -9
          ? '提取码错误'
          : '解析分享失败 (errno=${data['errno']})';
      throw Exception(msg);
    }

    final list = (data['data']?['list'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    // Exchange share key for a reusable "shareid" so stream URLs can be built.
    _shareSurlByShareId[surl] = surl;
    final items = list.map((f) => _fromBaiduShareFile(f)).toList();
    final title = data['data']?['title']?.toString() ?? '分享资源';

    return ShareParseResult(items: items, folderName: title);
  }

  /// Maps a share file id back to its surl (for later stream resolution).
  final Map<String, String> _shareSurlByShareId = {};

  DriveItem _fromBaiduShareFile(Map<String, dynamic> f) {
    final isDir = f['isdir'] == 1;
    final name = f['server_filename']?.toString() ?? '';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : null;
    final fsId = f['fs_id']?.toString() ?? '';
    if (fsId.isNotEmpty && f['surl'] != null) {
      _shareSurlByShareId[fsId] = f['surl'].toString();
    }
    return DriveItem(
      fileId: fsId,
      name: name,
      path: name,
      isDir: isDir,
      size: (f['size'] as num?)?.toInt() ?? 0,
      extension: ext,
      parentPath: '',
    );
  }

  // ------------------------------------------------------------------
  // Audio stream URLs
  // ------------------------------------------------------------------

  @override
  Future<ResolvedStream> getAudioStreamUrl(String fileId) async {
    if (_accessToken == null) throw StateError('Not authenticated');

    final response = await _dio.get(
      '$_apiBase/multimedia',
      queryParameters: {
        'method': 'filemetas',
        'fsids': '[$fileId]',
        'access_token': _accessToken,
        'dlink': 1,
      },
    );

    final data = response.data;
    if (data['errno'] != 0) {
      _checkErrno(data['errno']);
      throw Exception('Failed to get dlink: ${data['errno']}');
    }

    final list = data['list'] as List<dynamic>?;
    if (list == null || list.isEmpty) {
      throw Exception('No file metadata returned');
    }

    final dlink = list[0]['dlink']?.toString();
    if (dlink == null || dlink.isEmpty) {
      throw Exception('No dlink in response');
    }

    // dlink must be used with access_token; User-Agent is also required.
    return ResolvedStream(
      '$dlink&access_token=$_accessToken',
      headers: const {
        'User-Agent': 'pan.baidu.com',
      },
    );
  }

  @override
  Future<ResolvedStream> getShareAudioStreamUrl(String shareUrl, String fileId,
      {String? filename}) async {
    if (_cookie == null || _cookie!.isEmpty) {
      throw Exception('播放百度分享文件需要 Cookie（BDUSS）');
    }

    final surl = _shareSurlByShareId[fileId] ?? _extractSurl(shareUrl);
    final sign = await _getShareSign(surl);

    final resp = await _dio.post(
      '$_webBase/api/sharedownload',
      queryParameters: {
        'sign': sign['sign'],
        'timestamp': sign['timestamp'],
        'channel': 'chunlei',
        'web': 1,
        'app_id': 250528,
        'clienttype': 0,
      },
      data: {
        'encrypt': 0,
        'product': 'share',
        'type': 'dlink',
        'uk': '',
        'primaryid': surl,
        'fid_list': '[$fileId]',
      },
      options: Options(
        headers: {..._webAuthHeaders, 'Content-Type': 'application/x-www-form-urlencoded'},
      ),
    );

    final data = resp.data;
    if (data['errno'] != 0) {
      throw Exception('获取分享文件下载链接失败 (errno=${data['errno']})');
    }

    final list = data['list'] as List<dynamic>?;
    if (list == null || list.isEmpty) {
      throw Exception('未返回下载链接');
    }
    final dlink = list[0]['dlink']?.toString();
    if (dlink == null || dlink.isEmpty) {
      throw Exception('未返回下载链接');
    }

    return ResolvedStream(dlink, headers: _browserHeaders);
  }

  @override
  Future<Map<String, dynamic>> getAccountInfo() async {
    if (_accessToken == null) throw StateError('Not authenticated');

    final response = await _dio.get(
      '$_apiBase/userinfo',
      queryParameters: {
        'method': 'uinfo',
        'access_token': _accessToken,
      },
    );

    final data = response.data;
    if (data is Map && data['errno'] != null && data['errno'] != 0) {
      _checkErrno(data['errno']);
      throw Exception('Baidu API error: ${data['errno']}');
    }
    return data as Map<String, dynamic>;
  }
}
