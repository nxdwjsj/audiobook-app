import 'package:flutter/material.dart';
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
import 'services/storage_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
        ChangeNotifierProvider<BaiduDriveService>.value(value: baiduDrive),
        ChangeNotifierProvider<QuarkDriveService>.value(value: quarkDrive),
        ChangeNotifierProvider<AudioPlayerService>(
          create: (ctx) {
            final player = AudioPlayerService(
              ctx.read<ProgressRepository>(),
            );
            // 历史会话：手动点播新建记录，自动连播只更新
            player.sessionRepo = ctx.read<ListenSessionRepository>();
            // 收听时长统计：按天 + 按书累计
            player.statsRepo = ctx.read<StatsRepository>();
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
                      chapter.shareUrl!, chapter.fileId!);
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
      title: '听书',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
