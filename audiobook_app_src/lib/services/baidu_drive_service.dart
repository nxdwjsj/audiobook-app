import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/drive_item.dart';
import 'cloud_drive_service.dart';
import 'http/network_client.dart';
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

  /// 之前这里保存了百度官方 demo AppKey 作为兜底，但该 key 已被百度吊销，
  /// 未配置 AppKey 的用户点授权必然失败且报错不直观。现在不再内置任何
  /// 第三方凭据：未配置时返回空串，由登录页引导用户自行申请。
  static const String _redirectUri = 'oob';

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': 'https://pan.baidu.com/',
  };

  final Dio _dio;

  final StorageService _storage;
  String? _accessToken;
  String? _cookie;
  AuthStatus _authStatus = AuthStatus.unauthenticated;

  /// 最近一次校验是否被判定为「登录态失效」（errno=-6 或非 JSON 失效页）。
  /// 由 [_checkErrno] / [_probeToken] 置位；[init] 的启动校验据此决定落到
  /// expired 还是保持已连接（网络异常不能误导用户去换凭据）。
  bool _authFailureDetected = false;

  /// [init] 里 `unawaited` 出去的后台启动校验任务。
  Future<void>? _startupCheck;

  /// 启动校验超时上限（与夸克保持一致）。
  static const Duration _initVerifyTimeout = Duration(seconds: 5);

  /// [dio] 仅用于测试注入（伪造响应）；运行时不传，走 [createNetworkClient]。
  BaiduDriveService(this._storage, {Dio? dio})
      : _dio = dio ?? createNetworkClient(headers: _browserHeaders);

  /// 等待 [init] 触发的后台登录态校验结束。
  ///
  /// [init] 现在是「乐观置位 + 后台校验」，返回时校验通常还没跑完。生产代码
  /// 一般不需要它（UI 靠 `notifyListeners()` 刷新）；测试用它等到状态稳定，
  /// 避免用 `sleep` 猜时间。未调用过 [init]、或本地无凭据而未触发校验时，
  /// 返回一个已完成的 Future。
  Future<void> get startupCheckDone => _startupCheck ?? Future<void>.value();

  bool get _hasToken => _accessToken != null && _accessToken!.isNotEmpty;
  bool get _hasCookie => _cookie != null && _cookie!.isNotEmpty;

  /// The AppKey (API Key) used to build the OAuth authorize URL.
  /// 未配置时返回空串（不再回落到已吊销的 demo key）。
  String get clientId {
    final saved = _storage.getBaiduAppKey();
    if (saved != null && saved.isNotEmpty) return saved;
    return '';
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
    if (!_hasToken && !_hasCookie) {
      // 无凭据 → 直接未连接，不做乐观置位。
      _authStatus = AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }
    // 乐观置位 + 后台校验 + 事后纠正（与夸克 init 完全相同的容错策略）。
    //
    // 背景：本地存着 token / cookie 不等于它仍有效（可能已过期或被吊销）。
    // 此前这里只要有非空凭据就无条件置 authenticated 且**从不校验**，正是
    // 刚给夸克修掉的那个「永久假已连接」。现在首屏先乐观置为已连接让 UI 立刻
    // 可用，再后台打一次轻量接口校验；校验结束由 [_verifySavedCredential]
    // 统一 notifyListeners() 纠正状态（drive_login_page 等是 context.watch，
    // 能收到通知）。
    _authStatus = AuthStatus.authenticated;
    notifyListeners();
    final check = _verifySavedCredential();
    _startupCheck = check;
    unawaited(check);
  }

  /// 后台校验本地保存的凭据是否仍有效。
  ///
  /// 容错策略（与夸克一致）：只有被**明确判定**为登录态失效才置 expired；
  /// 超时 / 断网 / 未知错误一律保持已连接 —— 断网不是凭据的错，报成失效会让
  /// 用户反复重贴。
  ///
  /// 因为是 `unawaited` 的后台任务，有两条契约：
  /// - 结束时由它自己 `notifyListeners()`（[init] 不再重复通知，否则会白触发
  ///   一轮重建）；
  /// - **任何异常都必须在这里被吃掉**，否则会变成未捕获的异步异常（release
  ///   里就是一个崩溃点）。
  Future<void> _verifySavedCredential() async {
    try {
      await _validateCredential().timeout(_initVerifyTimeout);
      _authStatus = AuthStatus.authenticated;
    } on TimeoutException {
      // 校验超时按「未知」处理，保持已连接，别误导用户去换凭据
      _authStatus = AuthStatus.authenticated;
    } catch (e) {
      if (_isNetworkFailure(e)) {
        _authStatus = AuthStatus.authenticated;
      } else {
        _authStatus = _authFailureDetected
            ? AuthStatus.expired
            : AuthStatus.authenticated;
      }
    }
    // 唯一一次通知。单独包一层 try：即便 service 已被 dispose，
    // 也不能让这个后台任务把异常抛到 zone。
    try {
      notifyListeners();
    } catch (e) {
      debugPrint('[baidu] 启动校验后通知失败（已忽略）: $e');
    }
  }

  /// 轻量校验当前凭据是否仍有效：有 access_token 就查用户信息，否则用 Cookie
  /// 打一次 `nas?method=uinfo`。失败会抛异常；是否被判定为「登录态失效」记录
  /// 在 [_authFailureDetected]。**不**在这里 notify，由调用方统一通知一次。
  Future<void> _validateCredential() async {
    _authFailureDetected = false;
    if (_hasToken) {
      await _probeToken();
    } else if (_hasCookie) {
      await _probeCookie();
    }
  }

  /// 探测 access_token：非 JSON 失效页 / 业务 errno≠0 都抛异常，
  /// 其中 errno=-6 视为登录态失效（置 [_authFailureDetected]）。
  Future<void> _probeToken() async {
    final resp = await _dio.get(
      '$_apiBase/userinfo',
      queryParameters: {'method': 'uinfo', 'access_token': _accessToken},
    );
    final data = resp.data;
    if (data is! Map) {
      // 登录页 HTML 之类的非 JSON：除 5xx（服务端故障）外一律按失效处理
      if ((resp.statusCode ?? -1) < 500) _authFailureDetected = true;
      throw Exception('Baidu userinfo 响应非 JSON (HTTP ${resp.statusCode})');
    }
    final errno = data['errno'];
    if (errno != null && errno != 0) {
      if (_isInvalidTokenErrno(errno)) _authFailureDetected = true;
      throw Exception('Baidu API error: $errno');
    }
  }

  /// 探测 Cookie（BDUSS）：与 [setCookie] 共用同一条判定链路。
  Future<void> _probeCookie() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '$_apiBase/nas',
      queryParameters: {'method': 'uinfo'},
      options: Options(headers: {'Cookie': _cookie ?? ''}),
    );
    final errno = resp.data?['errno'];
    if (!isHttpSuccess(resp) || (errno is int && errno != 0)) {
      _authFailureDetected = true;
      throw Exception('Cookie 无效或已过期 (errno=$errno)');
    }
  }

  /// 是否为「连不上网」类失败：超时、连接超时、连接中断、请求取消等。
  /// 这类失败不能引导用户去换凭据（凭据本身可能还是好的）。
  bool _isNetworkFailure(Object e) {
    if (e is TimeoutException) return true;
    if (e is DioException) {
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.cancel;
    }
    return false;
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
  ///
  /// 与 setAccessToken / 夸克 setCookie 保持一致：先拿 Cookie 打一次轻量
  /// 接口验证有效，通过才落盘 —— 避免「粘了过期 Cookie → UI 显示已登录 →
  /// 所有分享解析都失败」的假登录态。
  Future<void> setCookie(String cookie) async {
    final trimmed = cookie.trim();
    final previous = _cookie;

    if (trimmed.isEmpty) {
      _cookie = null;
      await _storage.saveBaiduCookie('');
      _authStatus = _accessToken != null && _accessToken!.isNotEmpty
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated;
      notifyListeners();
      return;
    }

    _cookie = trimmed;
    try {
      await _probeCookie();
      await _storage.saveBaiduCookie(trimmed);
      _authStatus = AuthStatus.authenticated;
      notifyListeners();
    } catch (e) {
      _cookie = previous;
      _authStatus = (previous != null && previous.isNotEmpty) ||
              (_accessToken != null && _accessToken!.isNotEmpty)
          ? AuthStatus.authenticated
          : AuthStatus.expired;
      notifyListeners();
      throw Exception('Cookie 无效或已过期: $e');
    }
  }

  @override
  Future<void> logout() async {
    _accessToken = null;
    _cookie = null;
    _authFailureDetected = false;
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
    if (_isInvalidTokenErrno(errno)) {
      _authFailureDetected = true;
      _authStatus = AuthStatus.expired;
      notifyListeners();
    }
  }

  /// 百度在 access_token 失效 / 过期时返回 errno=-6。
  static bool _isInvalidTokenErrno(dynamic errno) {
    final code = errno is int ? errno : int.tryParse(errno?.toString() ?? '');
    return code == -6;
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
