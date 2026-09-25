import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:audiobook_app/models/book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/bookshelf_repository.dart';
import 'package:audiobook_app/repositories/progress_repository.dart';
import 'package:audiobook_app/services/audio_player_service.dart';
import 'package:audiobook_app/services/storage_service.dart';
import 'package:audiobook_app/widgets/mini_player_bar.dart';

/// 迷你播放栏是「不在播放页」时唯一能看到播放状态的地方：
/// 后台连播失败后必须在这里可见，并给出可操作的「重试」入口。
///
/// 这里用 [_FakePlayer] 直接构造界面状态，不走真实 playBook：
/// testWidgets 跑在 FakeAsync 下，just_audio 的流事件不会前进，
/// 靠异步把服务推到失败态会把测试挂死（假时钟不推进 Future.delayed）。
class _FakePlayer extends AudioPlayerService {
  _FakePlayer() : super(ProgressRepository(StorageService()));

  static const book = Book(
    id: 'drive_quark_b',
    title: '测试书',
    chapters: [
      Chapter(
        filename: 'a.mp3',
        title: '第 1 集',
        duration: Duration.zero,
        fileId: 'fid-1',
        driveType: DriveType.quark,
      ),
    ],
  );

  @override
  bool get hasBook => true;

  @override
  Book? get currentBook => book;

  @override
  Chapter? get currentChapter => book.chapters.first;

  @override
  int get currentChapterIndex => 0;

  @override
  Duration get position => const Duration(minutes: 1);

  @override
  Duration? get duration => const Duration(minutes: 10);

  @override
  bool get isPlaying => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpBar(WidgetTester tester, AudioPlayerService svc) {
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AudioPlayerService>.value(value: svc),
          ChangeNotifierProvider<BookshelfRepository>(
            create: (_) => BookshelfRepository(StorageService()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(bottomNavigationBar: MiniPlayerBar()),
        ),
      ),
    );
  }

  Future<void> unmountAndDispose(WidgetTester tester, AudioPlayerService svc) async {
    await tester.pumpWidget(const SizedBox()); // 先卸载，再释放服务
    svc.dispose();
  }

  testWidgets('失败态：显示失败文案与「重试」，不再显示「下一章」', (tester) async {
    final svc = _FakePlayer()
      ..lastError = '无法获取播放链接'
      ..retrying = false;

    await pumpBar(tester, svc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 高度动画落定

    expect(find.text('无法获取播放链接'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);
    expect(find.byTooltip('下一章'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountAndDispose(tester, svc);
  });

  testWidgets('静默退避中：显示失败文案与转圈，不给按钮（避免连点）', (tester) async {
    final svc = _FakePlayer()
      ..lastError = '网络不稳定，暂时连不上音频服务器'
      ..retrying = true;

    await pumpBar(tester, svc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('网络不稳定，暂时连不上音频服务器'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('重试'), findsNothing);
    expect(find.byTooltip('下一章'), findsNothing);

    await unmountAndDispose(tester, svc);
  });

  testWidgets('正常态：显示章节与「下一章」，没有重试入口', (tester) async {
    final svc = _FakePlayer()..lastError = null;

    await pumpBar(tester, svc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('1. 第 1 集'), findsOneWidget);
    expect(find.byTooltip('下一章'), findsOneWidget);
    expect(find.byTooltip('重试'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountAndDispose(tester, svc);
  });
}