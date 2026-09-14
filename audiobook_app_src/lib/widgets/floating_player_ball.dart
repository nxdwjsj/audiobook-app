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
/// - 单击展开迷你播放面板（封面/标题/上一章/播放/下一章/进入播放页/收起）
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

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();
    // 无书 / 播放页打开 / 面板展开中 → 不显示球
    if (!player.hasBook || PlayerPage.isShown) return const SizedBox.shrink();

    final size = MediaQuery.of(context).size;
    final dy = (_dyRatio * size.height).clamp(80.0, size.height - 160);

    return Positioned(
      left: _right ? size.width - ballSize - 8 : 8,
      top: dy,
      child: _expanded
          ? _buildPanel(context, player, size)
          : _buildBall(context, player),
    );
  }

  /// 收起状态的悬浮球
  Widget _buildBall(BuildContext context, AudioPlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
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

  /// 展开状态的迷你播放面板
  Widget _buildPanel(
      BuildContext context, AudioPlayerService player, Size size) {
    final scheme = Theme.of(context).colorScheme;
    final book = player.currentBook!;
    final panelWidth = (size.width - 32).clamp(280.0, 420.0);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      color: scheme.surface,
      child: Container(
        width: panelWidth,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5)),
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
                      setState(() => _expanded = false);
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
                          '第 ${player.currentChapterIndex + 1} 章',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
                // 收起按钮
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => setState(() => _expanded = false),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => player.previousChapter(),
                ),
                const SizedBox(width: 8),
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
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => player.nextChapter(),
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
      final size = MediaQuery.of(context).size;
      final newDy =
          (_dyRatio * size.height + d.delta.dy).clamp(80.0, size.height - 160);
      _dyRatio = newDy / size.height;
      // 拖过中线则换边
      final centerX = size.width / 2;
      final ballCenterX = _right
          ? size.width - ballSize / 2 - 8 + d.delta.dx
          : ballSize / 2 + 8 + d.delta.dx;
      _right = ballCenterX >= centerX;
    });
  }

  void _onPanEnd() {
    // 松手：贴边 + 持久化
    _persist();
  }
}
