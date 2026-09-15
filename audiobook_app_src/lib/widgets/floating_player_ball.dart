import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../services/audio_player_service.dart';
import '../services/storage_service.dart';
import '../pages/player_page.dart';
import 'throttled_navigator.dart';

/// 全局悬浮播放球：
/// - 可拖到屏幕任意位置（松手持久化；拖动期间水平/垂直都自由）
/// - 播放中收起时轻微上下跳动
/// - 单击从球的位置展开成小横条：左半图书信息（点击进播放页）、右半功能键
///   （上一章 / 播放暂停 / 下一章）；展开状态不遮罩，不挡下层页面操作，
///   再点横条空白处（或球）收起
/// - 无正在播放的书（player.hasBook == false）时自动隐藏
/// - 播放页已打开时自动隐藏（避免遮挡）
///
/// 挂载方式：MaterialApp.builder 里包在所有路由之上（见 main.dart）。
class FloatingPlayerBall extends StatefulWidget {
  const FloatingPlayerBall({super.key});

  @override
  State<FloatingPlayerBall> createState() => _FloatingPlayerBallState();
}

class _FloatingPlayerBallState extends State<FloatingPlayerBall>
    with SingleTickerProviderStateMixin {
  static const double ballSize = 52;

  /// 是否展开小横条
  bool _expanded = false;

  /// 球心位置（绝对像素，屏幕坐标系）
  late Offset _center;

  /// 本次手势是否构成拖动（超过阈值则不算点击）
  bool _dragging = false;

  /// 收起且播放中 → 跳动动画
  late final AnimationController _bounce =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final storage = context.read<StorageService>();
    final size = MediaQuery.of(context).size;
    // 新协议存球心比例；老用户没有 dx 时按「贴边侧」推算
    final dxRatio = storage.getBallDxRatio();
    final dyRatio = storage.getBallDyRatio().clamp(0.05, 0.9);
    _center = Offset(
      dxRatio.isNaN
          ? (storage.getBallRight()
              ? size.width - ballSize / 2 - 8
              : ballSize / 2 + 8)
          : (dxRatio * size.width)
              .clamp(ballSize / 2, size.width - ballSize / 2),
      (dyRatio * size.height).clamp(80.0, size.height - 160),
    );
    _initialized = true;
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    final storage = context.read<StorageService>();
    final size = MediaQuery.of(context).size;
    // 存球心比例（换分辨率/旋转后仍可用）
    await storage.saveBallDxRatio(_center.dx / size.width);
    await storage
        .saveBallDyRatio((_center.dy / size.height).clamp(0.05, 0.9));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();
    // 无书 / 播放页打开 → 不显示
    if (!player.hasBook || PlayerPage.isShown) {
      _expanded = false;
      return const SizedBox.shrink();
    }

    final size = MediaQuery.of(context).size;
    // 展开后球不再跳动（横条接管显示）
    final bounce = !_expanded && player.isPlaying
        ? Tween<double>(begin: -0, end: -6)
            .animate(CurvedAnimation(parent: _bounce, curve: Curves.easeInOut))
        : const AlwaysStoppedAnimation<double>(0);

    return AnimatedBuilder(
      animation: bounce,
      builder: (context, _) {
        final center = _center + Offset(0, bounce.value);
        return Stack(
          children: [
            if (_expanded)
              _buildBar(context, player, size, center)
            else
              _buildBall(context, player, center),
          ],
        );
      },
    );
  }

  /// 收起状态的悬浮球（可拖到任意位置）
  Widget _buildBall(BuildContext context, AudioPlayerService player, Offset center) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: center.dx - ballSize / 2,
      top: center.dy - ballSize / 2,
      child: GestureDetector(
        onPanStart: (_) => _dragging = true,
        onPanUpdate: (d) {
          setState(() {
            final size = MediaQuery.of(context).size;
            _center = Offset(
              (_center.dx + d.delta.dx).clamp(ballSize / 2, size.width - ballSize / 2),
              (_center.dy + d.delta.dy)
                  .clamp(60.0, size.height - ballSize / 2 - 20),
            );
          });
        },
        onPanEnd: (_) {
          if (_dragging) _persist();
          _dragging = false;
        },
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
              _ballCover(player.currentBook),
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

  /// 展开状态：从球的位置弹出小横条（左信息 + 右功能键），不遮罩不挡下层操作。
  /// 点击横条主体（信息区/封面）→ 进入播放页；点球位置的小圆点 → 收起。
  Widget _buildBar(
      BuildContext context, AudioPlayerService player, Size size, Offset center) {
    final scheme = Theme.of(context).colorScheme;
    final book = player.currentBook!;
    final chapter = player.currentChapter;
    const barWidth = 340.0;
    const barHeight = 64.0;

    // 横条位置：以球为锚点，整体夹在屏内
    final double barLeft =
        (center.dx - ballSize / 2 - 4).clamp(0.0, (size.width - barWidth).clamp(0.0, double.infinity));
    var barTop = center.dy - barHeight / 2;
    barTop = barTop.clamp(8.0, (size.height - barHeight - 16).clamp(8.0, double.infinity));

    return Stack(
      children: [
        Positioned(
          left: barLeft,
          top: barTop,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            color: scheme.surface.withValues(alpha: 0.97),
            child: Container(
              width: barWidth,
              height: barHeight,
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  // ---- 左半：图书信息（点击进播放页）----
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _expanded = false);
                        context.pushPlayerPage();
                      },
                      child: Row(
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
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
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
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // ---- 右半：功能键 ----
                  _barButton(
                    context,
                    icon: Icons.skip_previous_rounded,
                    tooltip: '上一章',
                    onTap: () => player.previousChapter(),
                  ),
                  _barButton(
                    context,
                    icon: player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: '播放/暂停',
                    accent: true,
                    onTap: () => player.playPause(),
                  ),
                  _barButton(
                    context,
                    icon: Icons.skip_next_rounded,
                    tooltip: '下一章',
                    onTap: () => player.nextChapter(),
                  ),
                  _barButton(
                    context,
                    icon: Icons.close_rounded,
                    tooltip: '收起',
                    onTap: () => setState(() => _expanded = false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _barButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      iconSize: accent ? 26 : 22,
      color: accent ? scheme.primary : scheme.onSurfaceVariant,
      onPressed: onTap,
      icon: Icon(icon),
    );
  }
}
