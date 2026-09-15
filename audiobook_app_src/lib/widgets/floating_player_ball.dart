import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../services/audio_player_service.dart';
import '../services/storage_service.dart';
import '../pages/player_page.dart';
import 'throttled_navigator.dart';

/// 全局悬浮播放球：
/// - 拖动可换位置，松手自动吸附到左右屏幕边缘（位置持久化）
/// - 单击展开迷你播放面板（封面/标题/章节/上一章/播放/下一章/进入播放页）
/// - 面板展开时屏幕盖半透明遮罩，点遮罩收起
/// - 无正在播放的书（player.hasBook == false）时自动隐藏
/// - 播放页已打开时自动隐藏（避免遮挡）
///
/// 挂载方式：MaterialApp.builder 里包在所有路由之上（见 main.dart）。
class FloatingPlayerBall extends StatefulWidget {
  const FloatingPlayerBall({super.key});

  @override
  State<FloatingPlayerBall> createState() => _FloatingPlayerBallState();
}

class _FloatingPlayerBallState extends State<FloatingPlayerBall> {
  static const double ballSize = 52;

  /// 是否展开迷你面板
  bool _expanded = false;

  /// 贴边侧（true = 右边）
  late bool _right;

  /// 垂直位置（占屏幕高度比例）
  late double _dyRatio;

  /// 本次手势累计水平位移（超过阈值才算拖动，松手时据此换边）
  double _panDx = 0;

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final storage = context.read<StorageService>();
    _right = storage.getBallRight();
    _dyRatio = storage.getBallDyRatio().clamp(0.05, 0.9);
    _initialized = true;
  }

  Future<void> _persist() async {
    final storage = context.read<StorageService>();
    await storage.saveBallRight(_right);
    await storage.saveBallDyRatio(_dyRatio);
  }

  /// 面板展开时，切页/播放页打开要顺带收起
  void _maybeCollapse() {
    if (_expanded) setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();
    // 无书 / 播放页打开 / 面板展开中 → 不显示球
    if (!player.hasBook || PlayerPage.isShown) {
      if (_expanded) _expanded = false; // 不 setState：本次本来就不渲染
      return const SizedBox.shrink();
    }

    final size = MediaQuery.of(context).size;
    final dy = (_dyRatio * size.height).clamp(80.0, size.height - 160);

    return Stack(
      children: [
        // 展开时盖半透明遮罩：点一下收起，也挡住下层页面误触
        if (_expanded)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = false),
              child: Container(color: Colors.black.withValues(alpha: 0.25)),
            ),
          ),
        // 球本体（展开时保持可见，作为面板锚点）
        Positioned(
          left: _right ? size.width - ballSize - 8 : 8,
          top: dy,
          child: _buildBall(context, player),
        ),
        // 展开面板：与球同侧对齐，放不下时翻到球上方
        if (_expanded)
          Builder(builder: (context) {
            const panelWidth = 320.0;
            const panelHeight = 150.0;
            final panelLeft = (_right ? size.width - 8 - panelWidth : 8.0)
                .clamp(8.0, (size.width - panelWidth - 8).clamp(8.0, double.infinity));
            var panelTop = dy + ballSize + 8;
            if (panelTop + panelHeight > size.height - 16) {
              panelTop = dy - panelHeight - 8; // 球太低 → 面板放上方
            }
            if (panelTop < 16) panelTop = 16;
            return Positioned(
              left: panelLeft,
              top: panelTop,
              child: _buildPanel(context, player, panelWidth),
            );
          }),
      ],
    );
  }

  /// 收起状态的悬浮球
  Widget _buildBall(BuildContext context, AudioPlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanStart: (_) => _panDx = 0,
      onPanUpdate: (d) => _onPan(d),
      onPanEnd: (_) => _onPanEnd(),
      onTap: () => setState(() => _expanded = true),
      child: Container(
        width: ballSize,
        height: ballSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.tertiary],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 封面（有则显示，无则显示图标）
            _ballCover(player.currentBook),
            // 播放中呼吸光环 + 状态图标
            if (player.isPlaying)
              Icon(
                Icons.graphic_eq_rounded,
                color: scheme.onPrimary.withValues(alpha: 0.95),
                size: 22,
              )
            else
              Icon(
                Icons.play_arrow_rounded,
                color: scheme.onPrimary.withValues(alpha: 0.95),
                size: 28,
              ),
          ],
        ),
      ),
    );
  }

  Widget _ballCover(Book? book) {
    if (book?.coverUrl == null) return const SizedBox.shrink();
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: book!.coverUrl!,
        fit: BoxFit.cover,
        width: ballSize,
        height: ballSize,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  /// 展开状态的迷你播放面板（位置由外层 Positioned 决定，这里只管内容）
  Widget _buildPanel(
      BuildContext context, AudioPlayerService player, double panelWidth) {
    final scheme = Theme.of(context).colorScheme;
    final book = player.currentBook!;
    final chapter = player.currentChapter;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: scheme.surface,
      child: Container(
        width: panelWidth,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: book.coverUrl != null
                        ? CachedNetworkImage(
                            imageUrl: book.coverUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                const SizedBox.shrink(),
                          )
                        : Icon(Icons.auto_stories_rounded,
                            color: scheme.primary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      _maybeCollapse();
                      context.pushPlayerPage();
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          chapter != null
                              ? '${player.currentChapterIndex + 1}. ${chapter.title}'
                              : '第 ${player.currentChapterIndex + 1} 集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: '上一章',
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => player.previousChapter(),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => player.playPause(),
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [scheme.primary, scheme.tertiary],
                      ),
                    ),
                    child: Icon(
                      player.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: scheme.onPrimary,
                      size: 30,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '下一章',
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => player.nextChapter(),
                ),
                const SizedBox(width: 4),
                // 进入播放页
                IconButton(
                  tooltip: '打开播放页',
                  icon: const Icon(Icons.open_in_full_rounded, size: 20),
                  onPressed: () {
                    _maybeCollapse();
                    context.pushPlayerPage();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _onPan(DragUpdateDetails d) {
    setState(() {
      _panDx += d.delta.dx;
      final size = MediaQuery.of(context).size;
      final newDy =
          (_dyRatio * size.height + d.delta.dy).clamp(80.0, size.height - 160);
      _dyRatio = newDy / size.height;
    });
  }

  void _onPanEnd() {
    // 松手：按本次手势累计位移换边 + 持久化
    setState(() {
      if (_panDx.abs() > 12) _right = _panDx > 0;
    });
    _persist();
  }
}
