import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/drive_item.dart';
import 'pages/home_page.dart';
import 'repositories/book_source_repository.dart';
import 'repositories/bookshelf_repository.dart';
import 'repositories/listen_session_repository.dart';
import 'repositories/progress_repository.dart';
import 'repositories/stats_repository.dart';
import 'services/audio_player_service.dart' show AudioPlayerService, AppAudioHandler;
import 'services/baidu_drive_service.dart';
import 'services/book_source/book_source_engine.dart';
import 'services/local_import_service.dart';
import 'services/log_service.dart';
import 'services/quark_drive_service.dart';
import 'services/cloud_drive_service.dart';
import 'services/resource_search_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';
import 'widgets/throttled_navigator.dart' show appNavigatorKey;

/// 统一的错误出口。四个来源都汇到这里：
/// `FlutterError.onError`、`PlatformDispatcher.instance.onError`、
/// `runZonedGuarded` 的异步异常、以及存储初始化重试。
///
/// 除了原有的 debugPrint（开发期看 logcat），这里**追加**一条落盘：
/// release 包 logcat 拿不到（也不该把细节打进去），崩溃只能靠私有目录的
/// `crash.log` 回捞。见 `services/log_service.dart`。
void reportError(Object error, StackTrace stack, {String tag = 'Error'}) {
  debugPrint('[$tag] $error');
  debugPrint('[$tag] 堆栈:\n$stack');
  // 后台写入，不阻塞错误处理路径。recordCrash 内部自带 try/catch 且永不抛出，
  // 所以这里不需要 await，也不会二次引发崩溃。
  //
  // 时序说明：LogService.instance 是懒加载静态字段，构造它没有副作用
  // （目录是在 recordCrash 内部按需解析的），因此无需在 main() 里显式提前
  // 初始化；本函数只会在 ensureInitialized() 之后被注册的处理器里调用。
  unawaited(LogService.instance.recordCrash(error, stack, tag: tag));
}

Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // 框架内部异常（红屏）默认不会把堆栈打到 logcat，这里显式打出来，
      // 否则真机上出问题只能看到红屏、拿不到堆栈。
      FlutterError.onError = (details) {
        reportError(details.exceptionAsString(), details.stack ?? StackTrace.current,
            tag: 'FlutterError');
        FlutterError.presentError(details);
      };
      // 原生层 / 插件抛出的异步异常不经过 FlutterError，必须单独接管。
      PlatformDispatcher.instance.onError = (error, stack) {
        reportError(error, stack, tag: 'Platform');
        return true;
      };

      // Initialize local storage
      Object? storageError;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await StorageService.init();
          storageError = null;
          break;
        } catch (e, st) {
          storageError = e;
          reportError(e, st, tag: 'StorageInit');
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }

      // 存储不可用时不静默继续：宁可给一个明确的错误页，也不要让用户
      // 在"书架莫名变空、写了不生效"的黑盒里排查。
      if (storageError != null || !StorageService.isStorageReady) {
        runApp(StorageFailureApp(error: storageError));
        return;
      }

      final storage = StorageService();

      // 动效降级：用户在设置里开启后，全局时长按比例压缩、曲线退化为线性。
      AppMotion.lowPerformance = storage.getReduceMotion();

      await bootstrapApp(storage);
    },
    (error, stack) => reportError(error, stack, tag: 'Zone'),
  );
}

/// 本地存储不可用时的兜底界面，提供重试。
class StorageFailureApp extends StatelessWidget {
  const StorageFailureApp({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '聆云',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage_rounded, size: 48),
                const SizedBox(height: 16),
                const Text(
                  '本地存储初始化失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  '书架、进度与登录状态都无法读写。\n'
                  '请确认设备存储空间充足后重试。\n\n$error',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () async {
                    await main();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> bootstrapApp(StorageService storage) async {

  // ProgressRepository 需要先创建，传给 AudioPlayerService（AudioHandler）
  final progressRepo = ProgressRepository(storage);

  // 通知栏 / 锁屏播放控制（MediaSession）。必须在 runApp 之前初始化。
  // 不再用 just_audio_background（Android 16 上 MediaSession 状态不更新），
  // 改为手动 AudioService.init，由 AudioPlayerService 内部持有一个
  // BaseAudioHandler 实例来推送播放状态。
  final playerService = AudioPlayerService(progressRepo);
  late final AppAudioHandler mediaSessionHandler;
  await AudioService.init(
    builder: () => mediaSessionHandler = AppAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.audiobook_app.channel.audio',
      androidNotificationChannelName: '播放控制',
      androidNotificationChannelDescription: '显示当前章节与播放进度',
      androidNotificationOngoing: true,
    ),
  );
  playerService.bindMediaSessionHandler(mediaSessionHandler);

  // Create and initialize drive services
  final baiduDrive = BaiduDriveService(storage);
  final quarkDrive = QuarkDriveService(storage);
  await baiduDrive.init();
  await quarkDrive.init();

  // 注入 AudioHandler 的依赖（原本在 Provider create 回调里做，现在提前到 main）
  final sessionRepo = ListenSessionRepository(storage);
  final statsRepo = StatsRepository(storage);

  // 书源：内置源（3 个在线听书站 + 5 个网盘分享发现）+ 用户自定义/导入。
  // 首次安装或随版本新增的内置源默认启用，用户手动开关会被持久化保留。
  final bookSourceRepo = BookSourceRepository(storage);
  await bookSourceRepo.load();

  playerService.sessionRepo = sessionRepo;
  playerService.statsRepo = statsRepo;
  playerService.storage = storage;
  playerService.streamUrlResolver = (chapter) async {
    if (chapter.driveType == null || chapter.fileId == null) return null;
    final isShare =
        chapter.shareUrl != null && chapter.shareUrl!.isNotEmpty;
    final service = chapter.driveType == DriveType.baidu
        ? baiduDrive
        : quarkDrive as CloudDriveService;
    try {
      if (isShare) {
        return await service.getShareAudioStreamUrl(
            chapter.shareUrl!, chapter.fileId!,
            filename: chapter.filename);
      }
      return await service.getAudioStreamUrl(chapter.fileId!);
    } catch (e, st) {
      debugPrint('Stream URL resolution error: $e\n$st');
      return null;
    }
  };
  // 取流失败时网盘服务已同步把 authStatus 置为 expired，播放器直接读即可，
  // 从而把「无法获取播放链接」换成「登录已失效，去重新连接」的可操作提示。
  playerService.cloudAuthExpiredChecker = () =>
      baiduDrive.authStatus == AuthStatus.expired ||
      quarkDrive.authStatus == AuthStatus.expired;

  // 在线书源章节懒解析：播放页 → 音频直链（书源规则驱动）。
  // chapter.shareUrl 存书源 id，播放器按 id 找对应规则。
  playerService.onlineAudioResolver = (sourceId, chapterUrl) async {
    if (sourceId.isEmpty) return null;
    final source = bookSourceRepo.all
        .where((s) => s.id == sourceId)
        .firstOrNull;
    if (source == null) {
      debugPrint('[OnlineAudio] 书源 $sourceId 不存在');
      return null;
    }
    try {
      return await BookSourceEngine(source).fetchOnlineAudio(chapterUrl);
    } catch (e) {
      debugPrint('[OnlineAudio] 解析失败 $chapterUrl: $e');
      return null;
    }
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<BookshelfRepository>(
          create: (_) => BookshelfRepository(storage),
        ),
        ChangeNotifierProvider<ProgressRepository>.value(
          value: progressRepo,
        ),
        ChangeNotifierProvider<ListenSessionRepository>.value(
          value: sessionRepo,
        ),
        ChangeNotifierProvider<StatsRepository>.value(
          value: statsRepo,
        ),
        ChangeNotifierProvider<BookSourceRepository>.value(
          value: bookSourceRepo,
        ),
        Provider<LocalImportService>(
          create: (ctx) => LocalImportService(
            ctx.read<BookshelfRepository>(),
          ),
        ),
        // 页面里用 context.read<StorageService>() 读写偏好（书架布局、转存目录）。
        // 必须注册成 Provider，否则取值时会抛 ProviderNotFoundException。
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider<BaiduDriveService>.value(value: baiduDrive),
        ChangeNotifierProvider<QuarkDriveService>.value(value: quarkDrive),
        Provider<ResourceSearchService>(
          create: (_) => ResourceSearchService(quarkDrive, bookSourceRepo),
        ),
        ChangeNotifierProvider<AudioPlayerService>.value(
          value: playerService,
        ),
      ],
      child: const AudiobookApp(),
    ),
  );
}

class AudiobookApp extends StatelessWidget {
  const AudiobookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '聆云',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.system,
      navigatorKey: appNavigatorKey,
      home: const HomePage(),
      // 播放控制入口已改为 HomePage 底部的常驻迷你播放条
      // （widgets/mini_player_bar.dart）：只在首页层级显示，进入
      // 推送路由时随首页一起被覆盖，不再需要全局 Overlay 挂载。
    );
  }
}
