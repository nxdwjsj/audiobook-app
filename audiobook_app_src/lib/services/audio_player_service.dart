import 'dart:async';
import 'dart:io' show InternetAddress;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/listen_session.dart';
import '../models/playback_progress.dart';
import '../repositories/listen_session_repository.dart';
import '../repositories/progress_repository.dart';
import '../repositories/stats_repository.dart';
import '../pages/player_page.dart';
import 'cloud_drive_service.dart';
import 'storage_service.dart';

/// Resolves a cloud drive chapter to a streamable URL plus any HTTP headers
/// required to fetch it (e.g. Baidu/Quark reject requests without a browser
/// User-Agent).
typedef StreamUrlResolverWithHeaders =
    Future<ResolvedStream?> Function(Chapter chapter);

/// 在线书源章节懒解析：播放页地址 → 音频直链。
/// 由 main.dart 注入（依赖 BookSourceRepository，播放器自身不持有）。
typedef OnlineAudioResolver =
    Future<String?> Function(String sourceId, String chapterUrl);

/// Manages audio playback state and controls.
/// Uses just_audio for playback and audio_service for MediaSession / notification.
/// 不直接继承 AudioHandler（Provider 要求 ChangeNotifier，而 BaseAudioHandler
/// 不是 ChangeNotifier），改为内部持有一个 AudioHandler 实例来推送状态。
class AudioPlayerService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final ProgressRepository _progressRepo;

  /// 推送给 MediaSession 的 handler（由 AudioService.init 注入）
  AppAudioHandler? _handler;

  /// 绑定 MediaSession handler（由 main.dart 在 AudioService.init 后调用）
  void bindMediaSessionHandler(AppAudioHandler handler) {
    _handler = handler;
    // 通知栏按钮点击 → 回调到播放控制
    handler.onPlay = playPause;
    handler.onPause = playPause;
    handler.onSkipToNext = nextChapter;
    handler.onSkipToPrevious = previousChapter;
  }

  /// 收听会话（历史记录数据源）：手动点播新建，自动连播只更新。
  ListenSessionRepository? sessionRepo;
  ListenSession? _activeSession;

  /// 收听时长统计（按天 + 按书）。
  StatsRepository? statsRepo;

  /// 播放设置来源（跳过片头/片尾秒数）。
  StorageService? storage;

  /// 切章进行中。切章是异步的，期间位置事件仍停留在旧章节末尾，
  /// 没有这层锁会连锁触发 nextChapter()，瞬间跳掉好几章并造成卡顿。
  bool _switchingChapter = false;

  /// 最后一次成功加载的章节索引（-1 = 未加载）。
  /// 「播放完成」与「片尾跳过」只对该索引生效：加载失败时没有新 source 载入，
  /// 播放器会一直停留在上一章的 completed / 片尾位置，此后每个 playbackEvent
  /// 都会再次命中自动连播分支 —— 网络波动时会连锁跳过好几章。
  int _loadedIndex = -1;

  /// 跳过片头秒数（0 = 不跳过）。按当前书查询，避免缓存与设置不同步。
  int get _skipIntroSeconds {
    final bookId = _currentBook?.id;
    if (bookId == null) return 0;
    return storage?.getSkipIntroSeconds(bookId) ?? 0;
  }

  /// 跳过片尾秒数（0 = 不跳过）。按当前书查询。
  int get _skipOutroSeconds {
    final bookId = _currentBook?.id;
    if (bookId == null) return 0;
    return storage?.getSkipOutroSeconds(bookId) ?? 0;
  }

  /// 上次统计打点时间；暂停时置空，避免把暂停/后台的间隔算成收听。
  DateTime? _lastStatsTick;

  /// 上次已对外通知的播放位置（整秒），用于给位置更新做节流。
  int _notifiedPositionSecond = -1;

  /// 上次已对外通知的播放位置（毫秒），用于更精细的节流控制。
  int _notifiedPositionMillisecond = -1;

  /// 尚未满 1 秒记账阈值的零头时长。
  Duration _pendingListen = Duration.zero;

  Book? _currentBook;
  List<Chapter> _chapters = [];
  int _currentChapterIndex = 0;

  // Sleep timer
  Timer? _sleepTimer;
  DateTime? _sleepEndTime;

  // Progress save debounce
  Timer? _progressSaveTimer;

  /// 下一章预加载：当前章播到 80% 时预解析下一章直链，切章零等待。
  /// key = chapter.fileId（网盘章节均有唯一 id）。
  final _resolvedCache = <String, ResolvedStream>{};
  String? _preloadedForFileId; // 已为哪个章节预加载过（防重复触发）

  /// Resolver for cloud drive audio stream URLs.
  /// Set by the app during initialization to connect drive services.
  StreamUrlResolverWithHeaders? streamUrlResolver;

  /// 在线书源章节懒解析：播放页 URL → 音频直链（由 main.dart 注入）。
  /// chapter.filename 存播放页地址，解析结果缓存在 [_onlineAudioCache]。
  OnlineAudioResolver? onlineAudioResolver;

  /// 在线书音频直链缓存：key = 播放页 URL。同一章重播/回退不再抓页面。
  final _onlineAudioCache = <String, String>{};

  /// 预加载中的在线章节（防并发重复请求同一播放页）。
  final _onlineAudioPending = <String, Future<String>>{};

  /// Error message from the last failed load, for UI display.
  String? lastError;

  /// 网盘登录态是否已失效（取流失败时判定）。
  /// 为 true 时 [lastError] 会换成「登录已失效」的文案，UI 据此给出
  /// 「去重新连接」入口，而不是让用户自己猜要不要重贴 Cookie。
  bool _cloudAuthExpired = false;

  /// 网盘登录态是否已失效。仅供 UI 读取。
  bool get cloudAuthExpired => _cloudAuthExpired;

  /// 判定网盘登录态是否失效的回调（由 main.dart 注入，读网盘服务的 authStatus）。
  /// 取流失败时网盘服务已同步把 authStatus 置为 expired，这里直接读即可，
  /// 不必去解析异常文本。
  bool Function()? cloudAuthExpiredChecker;

  /// 正在自动重试（界面提示用）。
  bool retrying = false;

  /// 自动连播失败重试：后台切章时可能遇到 DNS 解析失败、直链失效、
  /// 系统限制后台网络等，界面上没有重试入口，这里静默退避重试。
  /// 间隔前密后疏：校园网/移动网络下 DNS 常整段失效（实测中断 30 余秒），
  /// 前几次必须密，才能在网络恢复的瞬间立刻接上，而不是等完整退避周期。
  /// 合计约 3.5 分钟，覆盖得住常见的中断时长。
  static const _retryDelays = [3, 5, 8, 12, 18, 25, 35, 50, 60];
  int _advanceRetries = 0;
  Timer? _advanceRetryTimer;

  /// 回前台补试：后台期间重试全部失败时，用户回到前台再自动重试一次。
  AppLifecycleListener? _lifecycleListener;

  AudioPlayerService(this._progressRepo) {
    // Listen to playback events
    _player.playbackEventStream.listen(_onPlaybackEvent);
    _player.playerStateStream.listen((state) {
      // 暂停时清空打点基准，恢复播放后重新起算
      if (!state.playing) _lastStatsTick = null;
      notifyListeners();
    });
    _player.positionStream.listen((pos) {
      _tickStats();
      _maybeSkipOutro(pos);
      // 播放页 / 迷你栏都用 context.watch 订阅本服务，若每次位置更新都通知，
      // 会导致整页（含封面图）高频重建，表现为播放页卡顿。
      // 进度显示精度只到秒，因此仅在整秒变化时通知。
      // 但在播放页打开时，为了滑块拖动的平滑性，允许更频繁的通知
      final shouldNotify = PlayerPage.isShown 
          ? pos.inMilliseconds != _notifiedPositionMillisecond
          : pos.inSeconds != _notifiedPositionSecond;
          
      if (!shouldNotify) return;
      
      if (PlayerPage.isShown) {
        _notifiedPositionMillisecond = pos.inMilliseconds;
      } else {
        _notifiedPositionSecond = pos.inSeconds;
      }
      notifyListeners();
    });
    _player.durationStream.listen((_) => notifyListeners());
    // 通知栏 / 锁屏播放控制：播放状态变化时手动推送给 MediaSession。
    // 不再依赖 just_audio_background（Android 16 上 MediaSession 状态不更新），
    // 由本服务直接调用 audio_service 的 playbackState / mediaItem。
    _player.playbackEventStream.listen((_) => _pushMediaSessionState());
    _player.playerStateStream.listen((_) => _pushMediaSessionState());
    // 后台连播失败补试：回到前台时若仍处于失败状态，自动重试当前章节
    _lifecycleListener = AppLifecycleListener(
      onResume: () {
        if (lastError != null && _currentBook != null) {
          _advanceRetries = 0;
          _scheduleAdvanceRetry();
        }
      },
      // 切后台 / 锁屏 / 被系统回收前必须补一次落盘。
      // 原来只挂了 onResume，进程被强杀时会丢掉整个 debounce 周期
      // （旧逻辑 5s）的播放进度与收听时长。
      onPause: _flushOnLeave,
      onHide: _flushOnLeave,
      onDetach: _flushOnLeave,
    );
  }

  /// 离开前台时立即补写一次进度与统计。
  void _flushOnLeave() {
    if (_currentBook == null) return;
    unawaited(_saveProgress());
  }

  // --- Getters ---
  Book? get currentBook => _currentBook;
  Chapter? get currentChapter =>
      _chapters.isNotEmpty ? _chapters[_currentChapterIndex] : null;
  int get currentChapterIndex => _currentChapterIndex;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  double get speed => _player.speed;
  bool get hasBook => _currentBook != null;

  /// 跳过片头秒数（0 = 不跳过）。
  int get skipIntroSeconds => _skipIntroSeconds;

  /// 跳过片尾秒数（0 = 不跳过）。
  int get skipOutroSeconds => _skipOutroSeconds;

  Future<void> setSkipIntroSeconds(int seconds) async {
    final bookId = _currentBook?.id;
    if (bookId == null) return;
    await storage?.saveSkipIntroSeconds(bookId, seconds);
    notifyListeners();
  }

  Future<void> setSkipOutroSeconds(int seconds) async {
    final bookId = _currentBook?.id;
    if (bookId == null) return;
    await storage?.saveSkipOutroSeconds(bookId, seconds);
    notifyListeners();
  }

  bool get hasSleepTimer => _sleepTimer != null && _sleepTimer!.isActive;
  Duration? get sleepRemaining {
    if (_sleepEndTime == null) return null;
    final remaining = _sleepEndTime!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // --- Playback control ---
  /// 手动点播入口（书架/详情页/历史点“播放”）：新建收听会话。
  /// [startPosition] 用于从指定位置续播（历史记录 / 播放进度）。
  Future<void> playBook(
    Book book, {
    int startChapter = 0,
    Duration startPosition = Duration.zero,
  }) async {
    // 通知栏播放控制依赖通知权限（Android 13+），开始播放时申请时机最准
    await _ensureNotificationPermission();
    // 旧的重试任务不再适用（可能指向旧书的章节）
    _advanceRetryTimer?.cancel();
    _advanceRetries = 0;
    retrying = false;
    _loadedIndex = -1;
    // 空章节的书不切换当前书（避免 hasBook=true 但章节为空的半初始化状态，
    // 那会导致目录面板 clamp(0, -1) 崩溃）
    if (book.chapters.isEmpty) {
      notifyListeners();
      return;
    }
    _currentBook = book;
    _chapters = book.chapters;
    _currentChapterIndex = startChapter.clamp(0, _chapters.length - 1);

    await _startNewSession(startSeconds: startPosition.inSeconds);
    await _loadCurrentChapter();
    await _seekToStart(startPosition);
    await _player.play();
    notifyListeners();
  }

  /// 手动切章（详情页点某一章）：同样视为一次新的收听起点。
  /// [startPosition] 用于切到该章后再定位到指定进度（从历史记录续播）。
  Future<void> jumpToChapter(
    int index, {
    Duration startPosition = Duration.zero,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    _switchingChapter = true;
    _currentChapterIndex = index;
    await _startNewSession(startSeconds: startPosition.inSeconds);
    await _loadCurrentChapter();
    // 首次加载失败立刻重试一次：在线章节要在播放时抓播放页解析直链，
    // 站点限流/首次握手慢导致的偶发失败很常见。不重试的话界面已高亮新章
    // 却没有声音，用户只能再点一次目录（表现为「要点两次才切成功」）。
    if (lastError != null) {
      // 在线书源站点多有频控（如 275听书「操作太快」），立即重试必失败，
      // 歇一下再试；网盘章节无此限制，立即重试尽快恢复。
      if (_currentBook?.id.startsWith('online_') ?? false) {
        await Future.delayed(const Duration(milliseconds: 1300));
      }
      debugPrint('[Player] 切章首次失败，立即重试一次: ${_chapters[index].title}');
      await _loadCurrentChapter();
    }
    if (lastError != null) {
      _scheduleAdvanceRetry();
    } else {
      await _resumeAfterLoad(startPosition);
    }
    notifyListeners();
  }

  /// 新建收听会话（手动点播时调用）。
  /// 会话只是附属的历史数据，写入失败不能阻断播放——否则切章时目录已高亮
  /// 新章、音频却毫无反应（表现为「点了目录没播，要再点一次」）。
  Future<void> _startNewSession({int startSeconds = 0}) async {
    if (sessionRepo == null || _currentBook == null) return;
    try {
      _activeSession = await sessionRepo!.create(
        bookId: _currentBook!.id,
        bookTitle: _currentBook!.title,
        chapterIndex: _currentChapterIndex,
        positionSeconds: startSeconds,
        chapterCount: _chapters.length,
        chapterTitle: _chapters[_currentChapterIndex].title,
      );
    } catch (e) {
      debugPrint('[Player] 创建收听会话失败（不影响播放）: $e');
    }
  }

  /// 章节加载完成后定位起始位置：续播位置优先，否则套用「跳过片头」。
  Future<void> _seekToStart(Duration startPosition) async {
    if (lastError != null) return; // 加载失败，别动播放器
    final dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return;

    var target = startPosition;
    if (target <= Duration.zero) {
      final skip = _skipIntroSeconds;
      // 至少留 10 秒正片，避免短章节被整段跳完
      if (skip <= 0 || dur.inSeconds <= skip + 10) return;
      target = Duration(seconds: skip);
    }
    await _player.seek(target);
  }

  /// 片尾跳过：距结尾不足设定秒数时直接进入下一章（末章则直接结束）。
  void _maybeSkipOutro(Duration pos) {
    final skip = _skipOutroSeconds;
    if (skip <= 0) return;
    final dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return;
    // 章节本身不比片尾长多少时不做判定，否则会连跳整本书
    if (dur.inSeconds <= skip + 10) return;
    // 距结尾还早：说明已落到新章节（或用户回拖），解除切章锁
    if (dur - pos > Duration(seconds: skip)) {
      _switchingChapter = false;
      return;
    }
    // 正在切章 / 本章已跳过：直接忽略，否则会连锁触发 nextChapter()
    if (_switchingChapter) return;
    // 当前章节还没加载成功（网络失败重试中）：播放器位置仍停在上一章的片尾，
    // 据此判定「到片尾了」同样会连锁跳章
    if (_loadedIndex != _currentChapterIndex) return;
    _switchingChapter = true;

    if (_currentChapterIndex < _chapters.length - 1) {
      nextChapter();
    } else {
      _player.seek(dur);
    }
  }

  /// 通知栏播放控制是否被系统通知权限挡住（Android 13+ 用户拒绝时为 true）。
  /// 播放本身不受影响，只是通知栏 / 锁屏不会出现播放卡片。
  bool notificationBlocked = false;

  /// 「通知权限被拒」的提示是否已经弹过（避免每次进播放页都弹）
  bool notificationNoticeShown = false;

  bool _askedNotificationPermission = false;

  /// 申请通知权限（仅 Android 13+ 需要）。被拒不抛错，只置标志，
  /// 由 UI 提示用户去系统设置里打开。
  Future<void> _ensureNotificationPermission() async {
    if (_askedNotificationPermission) return;
    _askedNotificationPermission = true;
    try {
      var status = await Permission.notification.status;
      if (status.isGranted) return;
      status = await Permission.notification.request();
      if (!status.isGranted) {
        notificationBlocked = true;
        debugPrint('[Player] 通知权限被拒绝，通知栏不会显示播放控制');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[Player] 申请通知权限失败: $e');
    }
  }

  /// 通知栏 / 锁屏卡片展示的信息（just_audio_background 会读取音频源的 tag）。
  MediaItem _mediaItemFor(Chapter chapter) {
    final book = _currentBook;
    final cover = book?.coverUrl;
    final bookTitle = book?.title;
    final author = book?.author;
    return MediaItem(
      id: chapter.fileId ?? chapter.filename,
      title: chapter.title,
      album: (bookTitle != null && bookTitle.isNotEmpty) ? bookTitle : '聆云',
      artist: (author != null && author.isNotEmpty) ? author : '聆云',
      artUri: _artUriFor(cover),
    );
  }

  /// 通知栏封面 URI：本地文件绝对路径必须转成 file:// URI。
  /// 直接交给 artUri 的话 just_audio 会当成 HTTP 请求去拉，
  /// 报「No host specified in URI」——通知栏封面永远加载不出来。
  Uri? _artUriFor(String? cover) {
    if (cover == null || cover.isEmpty) return null;
    final parsed = Uri.tryParse(cover);
    if (parsed != null && parsed.hasScheme) return parsed;
    return Uri.file(cover);
  }

  /// 把 just_audio 的播放状态映射到 audio_service 的 PlaybackState，
  /// 推送给 MediaSession → 通知栏 / 锁屏播放控制卡片。
  /// 手动推送而非依赖 just_audio_background：
  /// just_audio_background 在 Android 16 上 MediaSession 状态永远不更新。
  void _pushMediaSessionState() {
    final handler = _handler;
    final chapter = currentChapter;
    if (handler == null || chapter == null) return;
    final playing = _player.playing;
    final processing = _player.processingState;
    final pos = _player.position;

    // 映射 just_audio 的 ProcessingState → audio_service 的 AudioProcessingState
    AudioProcessingState audioState;
    switch (processing) {
      case ProcessingState.idle:
        audioState = AudioProcessingState.idle;
        break;
      case ProcessingState.loading:
        audioState = AudioProcessingState.loading;
        break;
      case ProcessingState.buffering:
        audioState = AudioProcessingState.buffering;
        break;
      case ProcessingState.ready:
        audioState = AudioProcessingState.ready;
        break;
      case ProcessingState.completed:
        audioState = AudioProcessingState.completed;
        break;
    }

    handler.pushPlaybackState(handler.playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: audioState,
      playing: playing,
      updatePosition: pos,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentChapterIndex,
    ));
    // 通知栏时长显示：单独推送 duration（PlaybackState 里没有 duration 字段，
    // 需要通过 mediaItem 的 duration 或者系统自己从音频源取）
    final dur = _player.duration;
    if (dur != null) {
      handler.pushDuration(dur);
    }
  }

  /// 直链主机能不能解析出 IP。
  /// 校园网 / 移动网络下 CDN 域名会间歇性解析失败（errno 7），此时若直接交给
  /// just_audio，它内部要按 8 秒间隔重试，实测每次卡 ~20 秒才成功，
  /// 界面全程无反馈像卡死。这里主动探测，1~4 秒即可判定。
  /// 已是 IP 或解析不出主机名的 URL 视为可用（交给播放器自己处理）。
  Future<bool> _hostReachable(String url) async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return true;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      return addrs.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 确保直链主机可解析：不通就重新走一遍解析接口换条直链（服务端可能返回
  /// 其他区域节点）再试，最多 3 轮。全部失败返回 null。
  Future<ResolvedStream?> _ensureReachable(
      Chapter chapter, ResolvedStream resolved) async {
    var candidate = resolved;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _hostReachable(candidate.url)) return candidate;
      final host = Uri.tryParse(candidate.url)?.host;
      debugPrint('[Player] 直链主机解析失败，重新解析直链 '
          '(第 ${attempt + 1}/3 次): $host');
      if (attempt == 2) break;
      // 丢弃这条直链，避免重新解析又拿到同一条
      final fileId = chapter.fileId;
      if (fileId != null) _resolvedCache.remove(fileId);
      final resolver = streamUrlResolver;
      if (resolver == null) break;
      final retry = await resolver(chapter);
      if (retry == null) break;
      candidate = retry;
    }
    return null;
  }

  /// 在线章节懒解析：播放页 → 音频直链（缓存 + 并发去重）。
  /// [shareUrl] 存书源 id（加入书架时写入），resolver 据此找到对应规则。
  Future<String> _resolveOnlineAudio(Chapter chapter) async {
    final url = chapter.filename;
    final cached = _onlineAudioCache[url];
    if (cached != null) return cached;
    // 已有同 URL 请求在途 → 复用，不重复抓播放页
    final pending = _onlineAudioPending[url];
    if (pending != null) return pending;
    final resolver = onlineAudioResolver;
    if (resolver == null) {
      throw StateError('未配置在线书源解析器');
    }
    final sourceId = chapter.shareUrl ?? '';
    final future = resolver(sourceId, url).then((audio) {
      if (audio == null || audio.isEmpty) {
        throw StateError('在线书源没有解析出音频地址');
      }
      _onlineAudioCache[url] = audio;
      return audio;
    }).whenComplete(() => _onlineAudioPending.remove(url));
    _onlineAudioPending[url] = future;
    return future;
  }

  /// 在线书的防盗链 Referer：音频与章节所在站点同源时，取章节地址所在目录。
  /// 跨域（如 CDN 域名与站点不同）时不带，避免被 CDN 拒绝。
  String? _onlineRefererFor(Uri audioUri, String? chapterUrl) {
    if (chapterUrl == null || chapterUrl.isEmpty) return null;
    final chapter = Uri.tryParse(chapterUrl);
    if (chapter == null || chapter.host != audioUri.host) return null;
    final segs = chapter.pathSegments.toList();
    if (segs.isNotEmpty) segs.removeLast();
    return chapter.replace(pathSegments: segs, query: null).toString();
  }

  Future<void> _loadCurrentChapter() async {
    if (_currentBook == null || _chapters.isEmpty) return;

    final chapter = _chapters[_currentChapterIndex];
    // 本次加载的目标章节快照：重试定时器与用户手动切章可能叠在一起并发执行，
    // 旧请求返回时不能覆盖新章节的就位状态（否则自动连播会失效）
    final targetIndex = _currentChapterIndex;
    lastError = null;
    _cloudAuthExpired = false;
    // 注意：这里不要清 _switchingChapter。切章期间位置事件仍停在旧章节末尾，
    // 提前清掉会连锁触发再次跳章；该锁在落到新章节后由 _maybeSkipOutro 解除。
    debugPrint('[Player] 加载章节 ${_currentChapterIndex + 1}/${_chapters.length}: '
        '${chapter.title} (driveType=${chapter.driveType}, fileId=${chapter.fileId})');

    final needsResolver = chapter.fileId != null &&
        (chapter.driveType != null ||
            // 网盘章节: fileId 由网盘服务分配，driveType 对应提供商
            RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                .hasMatch(chapter.fileId!));
    // setUrl 内部已等待平台侧加载完成，返回值即为音频时长，无需再人为延迟校验
    Duration? loadedDuration;
    if (needsResolver) {
      // Cloud drive chapter: fetch real-time stream URL with headers.
      try {
        ResolvedStream resolved;
        // 预加载缓存命中：直接用已解析的直链（切章零等待）。
        // 直链带签名有效期，剩余不足 2 分钟视为过期（后台长时间播放后常见），重新解析。
        final cached = chapter.fileId != null
            ? _resolvedCache[chapter.fileId!]
            : null;
        final cachedRemaining =
            cached == null ? null : _urlRemainingSeconds(cached.url);
        if (cached != null &&
            (cachedRemaining == null || cachedRemaining >= 120)) {
          resolved = cached;
          debugPrint('[Player] 使用预加载缓存: ${chapter.title}');
        } else {
          if (cached != null) {
            _resolvedCache.remove(chapter.fileId!);
            debugPrint('[Player] 预加载直链即将过期，重新解析: ${chapter.title}');
          }
          if (streamUrlResolver == null) {
            lastError = '未配置网盘服务';
            debugPrint('[Player] $lastError');
            notifyListeners();
            return;
          }
          final result = await streamUrlResolver!(chapter);
          if (result == null) {
            _refreshCloudAuthExpired();
            // 只给一句「无法获取播放链接」的话，用户不知道要去重连网盘；
            // 判定为登录失效时直接把可操作的文案递给 UI。
            lastError = _cloudAuthExpired
                ? '登录已失效，请重新连接网盘'
                : '无法获取播放链接';
            debugPrint('[Player] $lastError');
            notifyListeners();
            return;
          }
          resolved = result;
        }
        // DNS 预检：域名解析不了就别交给播放器干等 20 秒，
        // 立刻重新解析直链换条地址再试（实测能把 20 秒压到几秒）
        final reachable = await _ensureReachable(chapter, resolved);
        if (reachable == null) {
          lastError = '网络不稳定，暂时连不上音频服务器';
          debugPrint('[Player] $lastError');
          notifyListeners();
          return;
        }
        debugPrint('[Player] 解析到流地址: ${reachable.url.substring(0, reachable.url.length.clamp(0, 120))}...');
        loadedDuration = await _player
            .setAudioSource(
              AudioSource.uri(
                Uri.parse(reachable.url),
                headers: reachable.headers,
              ),
            )
            // 兜底超时：极端网络下 setAudioSource 可能长时间不返回
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        lastError = '连接音频服务器超时';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      } catch (e) {
        _refreshCloudAuthExpired();
        lastError = _cloudAuthExpired
            ? '登录已失效，请重新连接网盘'
            : '获取播放链接失败: $e';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      }
    } else if (_currentBook!.id.startsWith('local_')) {
      // Local imported books store the file path in chapter.filename
      // 注意必须走 Uri.file：裸路径（/storage/.../x.mp3）用 Uri.parse
      // 会得到无 scheme 的相对 URI，just_audio 无法加载（表现为导入后没声音）。
      try {
        loadedDuration = await _player.setAudioSource(
          AudioSource.uri(Uri.file(chapter.filename)),
        );
      } catch (e) {
        lastError = '加载音频失败: $e';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      }
    } else if (_currentBook!.id.startsWith('online_')) {
      // 在线书源的书：chapter.filename 是章节地址（播放页或音频直链）。
      // 播放页需懒解析出音频直链（部分站点校验 Referer/UA 防盗链）。
      try {
        final audioUrl = await _resolveOnlineAudio(chapter);
        final uri = Uri.parse(audioUrl);
        if (!uri.isAbsolute ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          throw const FormatException('章节地址不是有效的 http 链接');
        }
        final referer = _onlineRefererFor(uri, chapter.filename);
        loadedDuration = await _player
            .setAudioSource(
              AudioSource.uri(
                uri,
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile '
                          'Safari/537.36',
                  if (referer != null) 'Referer': referer,
                },
              ),
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        lastError = '连接在线书源超时';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      } catch (e) {
        lastError = '加载在线音频失败: $e';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      }
    } else {
      // 无法解析的章节（既无网盘 fileId，也无本地文件路径）
      lastError = '该书章节无法播放（来源不支持或数据不完整）';
      debugPrint('[Player] $lastError');
      notifyListeners();
      return;
    }

    debugPrint('[Player] 加载完成: duration=${loadedDuration?.inSeconds}s '
        'processingState=${_player.processingState}');
    if ((loadedDuration == null || loadedDuration.inMilliseconds <= 0) &&
        _player.processingState == ProcessingState.idle) {
      lastError = '播放器未能加载音频（可能是格式不支持或链接失效）';
      debugPrint('[Player] $lastError');
    }
    // 只有真正加载成功才认这一章已就位，供自动连播 / 片尾跳过做判定
    if (lastError == null && _currentChapterIndex == targetIndex) {
      _loadedIndex = targetIndex;
      // 通知栏 / 锁屏显示当前章节信息
      _handler?.pushMediaItem(_mediaItemFor(chapter));
    }
    notifyListeners();
    _pushMediaSessionState();
  }

  Future<void> playPause() async {
    // 处于加载失败状态时，播放键即「手动重试」：
    // 否则用户点它没有任何反应（播放器还在 idle），只能干等自动重试
    if (lastError != null && !_player.playing) {
      _advanceRetryTimer?.cancel();
      _advanceRetries = 0;
      _resolvedCache.clear();
      _preloadedForFileId = null;
      await _loadCurrentChapter();
      if (lastError == null) {
        await _resumeAfterLoad();
      }
      notifyListeners();
      return;
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    // 手动拖动进度条：解除切章锁，让片尾跳过在新位置重新参与判定
    _switchingChapter = false;
    await _player.seek(position);
    notifyListeners();
  }

  Future<void> nextChapter() async {
    if (_currentChapterIndex < _chapters.length - 1) {
      _advanceRetryTimer?.cancel();
      _advanceRetries = 0;
      _switchingChapter = true;
      _currentChapterIndex++;
      await _loadCurrentChapter();
      if (lastError != null) {
        _scheduleAdvanceRetry();
      } else {
        await _resumeAfterLoad();
      }
      notifyListeners();
    }
  }

  Future<void> previousChapter() async {
    if (_currentChapterIndex > 0) {
      _advanceRetryTimer?.cancel();
      _advanceRetries = 0;
      _switchingChapter = true;
      _currentChapterIndex--;
      await _loadCurrentChapter();
      if (lastError != null) {
        _scheduleAdvanceRetry();
      } else {
        await _resumeAfterLoad();
      }
      notifyListeners();
    }
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    notifyListeners();
  }

  // --- Sleep timer ---
  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepEndTime = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _player.pause();
      _sleepTimer = null;
      _sleepEndTime = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndTime = null;
    notifyListeners();
  }

  // --- Progress persistence ---
  void _onPlaybackEvent(PlaybackEvent event) {
    // Auto-advance to next chapter when current ends
    if (event.processingState == ProcessingState.completed) {
      // 只对「已成功加载的当前章节」响应：加载失败时没有新 source 载入，
      // player 会一直停在 completed，后续每个事件都会再跳一章
      // （实测出现过 2 毫秒内连跳两章）
      if (_loadedIndex == _currentChapterIndex &&
          _currentChapterIndex < _chapters.length - 1) {
        nextChapter();
      }
    }

    // 下一章预加载：当前章播到 80% 时预解析下一章直链
    _maybePreloadNext();

    // Save progress periodically
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(seconds: 2), _saveProgress);
  }

  /// 当前章播到 80% 时预解析下一章（每章只触发一次）。
  Future<void> _maybePreloadNext() async {
    if (_currentBook == null ||
        _currentChapterIndex >= _chapters.length - 1 ||
        streamUrlResolver == null) {
      return;
    }
    final current = _chapters[_currentChapterIndex];
    final dur = _player.duration;
    if (dur == null || dur.inMilliseconds <= 0) return;
    if (_player.position < dur * 0.8) return;

    final next = _chapters[_currentChapterIndex + 1];
    final nextFileId = next.fileId;
    if (nextFileId == null || _resolvedCache.containsKey(nextFileId)) return;
    if (_preloadedForFileId == current.fileId) return;
    _preloadedForFileId = current.fileId;

    try {
      // 静默预解析，失败不打断播放
      final resolved = await streamUrlResolver!(next);
      if (resolved != null) {
        // 只保留下一章的缓存，避免过期直链堆积
        _resolvedCache
          ..clear()
          ..[nextFileId] = resolved;
        debugPrint('[Player] 已预加载下一章: ${next.title}');
      }
    } catch (e) {
      // 不再静默吞掉：登录态失效、直链接口报错通常最先在这里冒头，
      // 用户下次反馈时 logcat 里要有据可查。不打断播放，切章时走正常解析。
      debugPrint('[Player] 预加载下一章失败: ${next.title} → $e');
    }
  }

  /// 重新判定网盘登录态是否失效（取流失败后调用）。
  void _refreshCloudAuthExpired() {
    _cloudAuthExpired = cloudAuthExpiredChecker?.call() ?? false;
  }

  /// 按墙钟增量累计「真正在播放」的时长。
  /// positionStream 仅在播放时持续触发，配合暂停时清空基准，可避免把
  /// 暂停 / 切后台的间隔算成收听时间。
  void _tickStats() {
    final now = DateTime.now();
    final last = _lastStatsTick;
    _lastStatsTick = now;
    if (last == null || !_player.playing || statsRepo == null) return;
    final delta = now.difference(last);
    // 间隔异常（系统冻结、长时间挂起）直接丢弃
    if (delta <= Duration.zero || delta > const Duration(seconds: 60)) return;
    _pendingListen += delta;
    // 满 10 秒才记一次账，减少 Hive 写入与通知频率
    if (_pendingListen.inSeconds < 10) return;
    final seconds = _pendingListen.inSeconds;
    _pendingListen -= Duration(seconds: seconds);
    statsRepo!.addSeconds(
      seconds,
      bookId: _currentBook?.id,
      bookTitle: _currentBook?.title,
    );
  }

  /// 加载成功后接上播放，并清掉自动重试状态。
  /// 必须重置 retrying：否则用户手动切章成功后，播放页会一直挂着
  /// 「正在自动重试…」的假提示。
  /// [startPosition] 为续播起点（默认 0，即按「跳过片头」规则从头开始）。
  Future<void> _resumeAfterLoad([Duration startPosition = Duration.zero]) async {
    _advanceRetryTimer?.cancel();
    _advanceRetries = 0;
    retrying = false;
    await _seekToStart(startPosition);
    await _player.play();
  }

  /// 自动连播失败重试：后台切章时可能遇到 CDN 域名解析失败、直链失效、
  /// 系统限制后台网络等，界面上没有重试入口，这里静默退避重试。
  /// 间隔前密后疏（3~60 秒，合计约 3.5 分钟），网络恢复的瞬间即可接上；
  /// 每次重试前清空预加载缓存，强制重新解析新直链。
  void _scheduleAdvanceRetry() {
    if (_currentBook == null || _currentChapterIndex >= _chapters.length) {
      return;
    }
    if (_advanceRetries >= _retryDelays.length) {
      retrying = false;
      notifyListeners();
      return;
    }
    final delay = Duration(seconds: _retryDelays[_advanceRetries]);
    _advanceRetries++;
    retrying = true;
    _advanceRetryTimer?.cancel();
    _advanceRetryTimer = Timer(delay, () async {
      // 期间用户已手动恢复（换书 / 已接上播放）→ 放弃本次重试
      if (_currentBook == null || lastError == null) {
        retrying = false;
        notifyListeners();
        return;
      }
      // 旧直链（含预加载缓存）大概率已失效，丢弃重新解析；
      // 在线书源的音频地址多数带时效签名（sign/timestamp），
      // 不清掉的话重试多少次拿到的还是那个过期地址
      _resolvedCache.clear();
      _onlineAudioCache.clear();
      _preloadedForFileId = null;
      await _loadCurrentChapter();
      if (lastError == null) {
        await _resumeAfterLoad();
      } else {
        _scheduleAdvanceRetry();
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// 直链 URL 的剩余有效秒数（解析查询参数里的 Expires / x-oss-expires）。
  /// 解析不出返回 null（视为长期有效）。
  int? _urlRemainingSeconds(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    for (final key in const ['Expires', 'expires', 'x-oss-expires']) {
      final raw = uri.queryParameters[key];
      if (raw == null) continue;
      final expireAt = int.tryParse(raw);
      if (expireAt == null) continue;
      return expireAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }

  /// 把零头时长记账并落盘（随进度保存一起触发）。
  Future<void> _flushStats() async {
    final repo = statsRepo;
    if (repo == null) return;
    final pending = _pendingListen.inSeconds;
    if (pending > 0) {
      _pendingListen -= Duration(seconds: pending);
      repo.addSeconds(
        pending,
        bookId: _currentBook?.id,
        bookTitle: _currentBook?.title,
      );
    }
    await repo.flush();
  }

  Future<void> _saveProgress() async {
    await _flushStats();
    if (_currentBook == null) return;
    final progress = _player.position;
    await _progressRepo.saveProgress(
      PlaybackProgress(
        bookId: _currentBook!.id,
        chapterIndex: _currentChapterIndex,
        positionSeconds: progress.inSeconds,
        bookTitle: _currentBook!.title,
        chapterCount: _chapters.length,
      ),
    );
    // 会话进度同步（自动连播也只更新当前会话，不新建）
    final session = _activeSession;
    if (sessionRepo != null && session != null) {
      await sessionRepo!.updateProgress(
        session,
        chapterIndex: _currentChapterIndex,
        positionSeconds: progress.inSeconds,
        chapterTitle: _chapters[_currentChapterIndex].title,
      );
    }
  }

  /// Resume playback from saved progress.
  Future<void> resumeFromProgress(Book book) async {
    final saved = _progressRepo.getProgress(book.id);
    if (saved == null) {
      await playBook(book);
      return;
    }
    await playBook(
      book,
      startChapter: saved.chapterIndex,
      startPosition: Duration(seconds: saved.positionSeconds),
    );
  }

  /// Stop playback and release resources.
  Future<void> stop() async {
    await _saveProgress();
    _advanceRetryTimer?.cancel();
    retrying = false;
    _loadedIndex = -1;
    await _player.stop();
    _currentBook = null;
    _chapters = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _progressSaveTimer?.cancel();
    _advanceRetryTimer?.cancel();
    _lifecycleListener?.dispose();
    _player.dispose();
    super.dispose();
  }
}

/// 推送给 MediaSession 的 AudioHandler 实现。
/// 接收 AudioPlayerService 手动推送的播放状态与 MediaItem，
/// 同时把通知栏按钮点击事件回调给 AudioPlayerService。
class AppAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  /// 通知栏按钮点击回调（由 AudioPlayerService 注入）
  void Function()? onPlay;
  void Function()? onPause;
  void Function()? onSkipToNext;
  void Function()? onSkipToPrevious;

  void pushPlaybackState(PlaybackState state) {
    playbackState.add(state);
  }

  void pushMediaItem(MediaItem item) {
    mediaItem.add(item);
  }

  /// 推送时长给通知栏（通过更新当前 mediaItem 的 duration）
  void pushDuration(Duration duration) {
    final item = mediaItem.value;
    if (item != null) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToNext() async => onSkipToNext?.call();

  @override
  Future<void> skipToPrevious() async => onSkipToPrevious?.call();
}

