import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'models/drive_item.dart';
import 'pages/home_page.dart';
import 'repositories/bookshelf_repository.dart';
import 'repositories/listen_session_repository.dart';
import 'repositories/progress_repository.dart';
import 'repositories/stats_repository.dart';
import 'services/audio_player_service.dart';
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

  // 通知栏 / 锁屏播放控制（MediaSession）。必须在 runApp 之前初始化一次，
  // 之后 AudioPlayer 的音频源只要带 MediaItem tag 就会自动出现在通知栏。
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.audiobook_app.channel.audio',
    androidNotificationChannelName: '播放控制',
    androidNotificationChannelDescription: '显示当前章节与播放进度',
    androidNotificationOngoing: true,
  );

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

  // Create and initialize drive services
  final baiduDrive = BaiduDriveService(storage);
  final quarkDrive = QuarkDriveService(storage);
  await baiduDrive.init();
  await quarkDrive.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<BookshelfRepository>(
          create: (_) => BookshelfRepository(storage),
        ),
        ChangeNotifierProvider<ProgressRepository>(
          create: (_) => ProgressRepository(storage),
        ),
        ChangeNotifierProvider<ListenSessionRepository>(
          create: (_) => ListenSessionRepository(storage),
        ),
        ChangeNotifierProvider<StatsRepository>(
          create: (_) => StatsRepository(storage),
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
        ChangeNotifierProvider<AudioPlayerService>(
          create: (ctx) {
            final player = AudioPlayerService(
              ctx.read<ProgressRepository>(),
            );
            // 历史会话：手动点播新建记录，自动连播只更新
            player.sessionRepo = ctx.read<ListenSessionRepository>();
            // 收听时长统计：按天 + 按书累计
            player.statsRepo = ctx.read<StatsRepository>();
            // 播放设置（跳过片头 / 跳过片尾秒数）
            player.storage = storage;
            // Set up stream URL resolver for cloud drive chapters.
            player.streamUrlResolver = (chapter) async {
              if (chapter.driveType == null || chapter.fileId == null) {
                return null;
              }
              final isShare =
                  chapter.shareUrl != null && chapter.shareUrl!.isNotEmpty;
              // Route by the chapter's own provider — a Quark share must not
              // be handed to the Baidu service (and vice-versa).
              final service = chapter.driveType == DriveType.baidu
                  ? ctx.read<BaiduDriveService>()
                  : ctx.read<QuarkDriveService>() as CloudDriveService;
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
            return player;
          },
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
