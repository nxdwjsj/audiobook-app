import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/listen_session.dart';
import '../models/playback_progress.dart';
import '../repositories/listen_session_repository.dart';
import '../repositories/progress_repository.dart';
import 'cloud_drive_service.dart';

/// Resolves a cloud drive chapter to a streamable URL plus any HTTP headers
/// required to fetch it (e.g. Baidu/Quark reject requests without a browser
/// User-Agent).
typedef StreamUrlResolverWithHeaders =
    Future<ResolvedStream?> Function(Chapter chapter);

/// Manages audio playback state and controls.
/// Uses just_audio for playback and Provider for state notification.
class AudioPlayerService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final ProgressRepository _progressRepo;

  /// 收听会话（历史记录数据源）：手动点播新建，自动连播只更新。
  ListenSessionRepository? sessionRepo;
  ListenSession? _activeSession;

  Book? _currentBook;
  List<Chapter> _chapters = [];
  int _currentChapterIndex = 0;

  // Sleep timer
  Timer? _sleepTimer;
  DateTime? _sleepEndTime;

  // Progress save debounce
  Timer? _progressSaveTimer;

  /// 下一章预加载：当前章播到 80% 时预解析下一章直链，切章零等待。
  /// key = chapter.fileId（网盘/在线源章节均有唯一 id）。
  final _resolvedCache = <String, ResolvedStream>{};
  String? _preloadedForFileId; // 已为哪个章节预加载过（防重复触发）

  /// Resolver for cloud drive audio stream URLs.
  /// Set by the app during initialization to connect drive services.
  StreamUrlResolverWithHeaders? streamUrlResolver;

  /// Legacy resolver for backward compatibility (will be removed).
  // ignore: unused_field
  StreamUrlResolverWithHeaders? streamUrlResolverLegacy;

  /// Error message from the last failed load, for UI display.
  String? lastError;

  AudioPlayerService(this._progressRepo) {
    // Listen to playback events
    _player.playbackEventStream.listen(_onPlaybackEvent);
    _player.playerStateStream.listen((_) => notifyListeners());
    _player.positionStream.listen((_) => notifyListeners());
    _player.durationStream.listen((_) => notifyListeners());
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

  bool get hasSleepTimer => _sleepTimer != null && _sleepTimer!.isActive;
  Duration? get sleepRemaining {
    if (_sleepEndTime == null) return null;
    final remaining = _sleepEndTime!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // --- Playback control ---
  /// 手动点播入口（书架/详情页/历史点“播放”）：新建收听会话。
  Future<void> playBook(Book book, {int startChapter = 0}) async {
    _currentBook = book;
    _chapters = book.chapters;
    if (_chapters.isEmpty) {
      notifyListeners();
      return;
    }
    _currentChapterIndex = startChapter.clamp(0, _chapters.length - 1);

    await _startNewSession();
    await _loadCurrentChapter();
    await _player.play();
    notifyListeners();
  }

  /// 手动切章（详情页点某一章）：同样视为一次新的收听起点。
  Future<void> jumpToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    _currentChapterIndex = index;
    await _startNewSession();
    await _loadCurrentChapter();
    await _player.play();
    notifyListeners();
  }

  /// 新建收听会话（手动点播时调用）。
  Future<void> _startNewSession() async {
    if (sessionRepo == null || _currentBook == null) return;
    _activeSession = await sessionRepo!.create(
      bookId: _currentBook!.id,
      bookTitle: _currentBook!.title,
      chapterIndex: _currentChapterIndex,
      positionSeconds: 0,
      chapterCount: _chapters.length,
      chapterTitle: _chapters[_currentChapterIndex].title,
    );
  }

  Future<void> _loadCurrentChapter() async {
    if (_currentBook == null || _chapters.isEmpty) return;

    final chapter = _chapters[_currentChapterIndex];
    lastError = null;
    debugPrint('[Player] 加载章节 ${_currentChapterIndex + 1}/${_chapters.length}: '
        '${chapter.title} (driveType=${chapter.driveType}, fileId=${chapter.fileId})');

    final needsResolver = chapter.fileId != null &&
        (chapter.driveType != null ||
            // 网盘章节: fileId 由网盘服务分配，driveType 对应提供商
            RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                .hasMatch(chapter.fileId!));
    if (needsResolver) {
      // Cloud drive chapter: fetch real-time stream URL with headers.
      try {
        ResolvedStream resolved;
        // 预加载缓存命中：直接用已解析的直链（切章零等待）
        final cached = chapter.fileId != null
            ? _resolvedCache[chapter.fileId!]
            : null;
        if (cached != null) {
          resolved = cached;
          debugPrint('[Player] 使用预加载缓存: ${chapter.title}');
        } else if (streamUrlResolver != null) {
          final result = await streamUrlResolver!(chapter);
          if (result == null) {
            lastError = '无法获取播放链接';
            debugPrint('[Player] $lastError');
            notifyListeners();
            return;
          }
          resolved = result;
        } else {
          lastError = '未配置网盘服务';
          debugPrint('[Player] $lastError');
          notifyListeners();
          return;
        }
        debugPrint('[Player] 解析到流地址: ${resolved.url.substring(0, resolved.url.length.clamp(0, 120))}...');
        await _player.setUrl(resolved.url, headers: resolved.headers);
      } catch (e) {
        lastError = '获取播放链接失败: $e';
        debugPrint('[Player] $lastError');
        notifyListeners();
        return;
      }
    } else if (_currentBook!.id.startsWith('local_')) {
      // Local imported books store the file path in chapter.filename
      try {
        await _player.setUrl(chapter.filename);
      } catch (e) {
        lastError = '加载音频失败: $e';
        debugPrint('[Player] $lastError');
        notifyListeners();
      }
    } else {
      // 无法解析的章节（本地文件且非 local_ 前缀、或已从书架移除的在线书）
      lastError = '该书章节无法播放（来源不支持或数据不完整）';
      debugPrint('[Player] $lastError');
      notifyListeners();
      return;
    }

    // Verify the player actually got a playable stream (has duration).
    if (lastError == null) {
      await Future.delayed(const Duration(milliseconds: 800));
      final dur = _player.duration;
      debugPrint('[Player] 加载完成: duration=${dur?.inSeconds}s '
          'processingState=${_player.processingState}');
      if (dur == null || dur.inMilliseconds <= 0) {
        if (_player.processingState == ProcessingState.idle) {
          lastError = '播放器未能加载音频（可能是格式不支持或链接失效）';
          debugPrint('[Player] $lastError');
        }
      }
    }
    notifyListeners();
  }

  Future<void> playPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    notifyListeners();
  }

  Future<void> nextChapter() async {
    if (_currentChapterIndex < _chapters.length - 1) {
      _currentChapterIndex++;
      await _loadCurrentChapter();
      await _player.play();
      notifyListeners();
    }
  }

  Future<void> previousChapter() async {
    if (_currentChapterIndex > 0) {
      _currentChapterIndex--;
      await _loadCurrentChapter();
      await _player.play();
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
      if (_currentChapterIndex < _chapters.length - 1) {
        nextChapter();
      }
    }

    // 下一章预加载：当前章播到 80% 时预解析下一章直链
    _maybePreloadNext();

    // Save progress periodically
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(seconds: 5), _saveProgress);
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
    } catch (_) {
      // 预加载失败：切章时走正常解析
    }
  }

  Future<void> _saveProgress() async {
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
    if (saved != null) {
      await playBook(book, startChapter: saved.chapterIndex);
      // Seek to saved position after loading
      await Future.delayed(const Duration(milliseconds: 500));
      if (saved.positionSeconds > 0) {
        await seek(Duration(seconds: saved.positionSeconds));
      }
    } else {
      await playBook(book);
    }
  }

  /// Stop playback and release resources.
  Future<void> stop() async {
    await _saveProgress();
    await _player.stop();
    _currentBook = null;
    _chapters = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _progressSaveTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}

