import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/drive_item.dart';
import 'pages/home_page.dart';
import 'repositories/bookshelf_repository.dart';
import 'repositories/listen_session_repository.dart';
import 'repositories/progress_repository.dart';
import 'repositories/stats_repository.dart';
import 'services/audio_player_service.dart' show AudioPlayerService, AppAudioHandler;
import 'services/baidu_drive_service.dart';
import 'services/local_import_service.dart';
import 'services/quark_drive_service.dart';
import 'services/cloud_drive_service.dart';
import 'services/resource_search_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';
import 'widgets/floating_player_ball.dart';
import 'widgets/throttled_navigator.dart' show appNavigatorKey;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 框架内部异常（红屏）默认不会把堆栈打到 logcat，这里显式打出来，
  // 否则真机上出问题只能看到红屏、拿不到堆栈。
  FlutterError.onError = (details) {
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
    debugPrint('[FlutterError] 上下文: ${details.context}');
    debugPrint('[FlutterError] 堆栈:\n${details.stack}');
    FlutterError.presentError(details);
  };

  // Initialize local storage
  try {
    await StorageService.init();
  } catch (e) {
    debugPrint('Storage init failed: $e');
  }

  final storage = StorageService();

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
          create: (_) => ResourceSearchService(quarkDrive),
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
      // 全局悬浮播放球：盖在所有路由（含底部导航栏）之上，
      // 播放页打开或无正在播放的书时自动隐藏。
      builder: (context, child) => Stack(
        children: [
          child ?? const SizedBox.shrink(),
          const FloatingPlayerBall(),
        ],
      ),
    );
  }
}
