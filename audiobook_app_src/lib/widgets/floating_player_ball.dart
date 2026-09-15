import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../pages/player_page.dart';
import '../repositories/bookshelf_repository.dart';
import '../services/audio_player_service.dart';
import '../services/storage_service.dart';
import 'throttled_navigator.dart';

/// 全局悬浮播放球：
/// - 可拖到屏幕任意位置（松手持久化；拖动期间水平/垂直都自由）
/// - 播放中收起时球内显示跳动的声波条（球本体不位移）
/// - 封面优先取书架的自定义封面（用户从相册选的），其次本地路径、网络封面
/// - 单击从球的位置展开成小横条：左半图书信息（点击进播放页）、右半功能键
///   （上一章 / 播放暂停 / 下一章）；展开状态不遮罩，不挡下层页面操作
/// - 展开后在屏幕任意位置滑动 → 自动收回成球
/// - 无正在播放的书（player.hasBook == false）时自动隐藏
/// - 播放页已打开时自动隐藏（避免遮挡）
///
/// 挂载方式：MaterialApp.builder 里包在所有路由之上（见 main.dart）。
/// 注意：本组件不在 Navigator 子树内，跳转必须走 appNavigatorKey
/// （见 throttled_navigator.dart）。
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

  /// 展开状态下累计的滑动量（超过阈值收起回球）
  double _moveAccum = 0;

  /// 收起且播放中 → 球内声波条动画（build 里按需 repeat/stop，不常驻空转）
  late final AnimationController _wave = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));

  bool _initialized = false;
  Size _lastSize = Size.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.of(context).size;
    if (_initialized) {
      // 旋转屏幕 / 窗口尺寸变化：按新旧尺寸比例重算球心，防止球停在可视区外
      if (_lastSize != size && _lastSize != Size.zero) {
        setState(() {
          _center = Offset(
            (_center.dx / _lastSize.width * size.width)
                .clamp(ballSize / 2, size.width - ballSize / 2),
            (_center.dy / _lastSize.height * size.height)
                .clamp(80.0, size.height - 160),
          );
        });
      }
      _lastSize = size;
      return;
    }
    final storage = context.read<StorageService>();
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
    _lastSize = size;
    _initialized = true;
  }

  @override
  void dispose() {
    _wave.dispose();
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
      _stopWaveIfNeeded();
      return const SizedBox.shrink();
    }

    final size = MediaQuery.of(context).size;
    // 声波动画按需启停：只在「收起 + 播放中」跑，其余状态停掉（省电省 CPU）
    if (!_expanded && player.isPlaying) {
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      _stopWaveIfNeeded();
    }

    // 展开时全屏监听指针滑动（translucent：不拦截下层页面操作），
    // 任意位置滑动超过阈值 → 自动收起回球
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _expanded ? (_) => _moveAccum = 0 : null,
      onPointerMove: _expanded
          ? (d) {
              _moveAccum += d.delta.dx.abs() + d.delta.dy.abs();
              if (_moveAccum > 28) {
                _moveAccum = 0;
                setState(() => _expanded = false);
              }
            }
          : null,
      child: Stack(
        children: [
          if (_expanded)
            _buildBar(context, player, size)
          else
            _buildBall(context, player),
        ],
      ),
    );
  }

  void _stopWaveIfNeeded() {
    if (_wave.isAnimating) _wave.stop();
  }

  /// 解析书籍封面：书架自定义本地封面 > 本地路径 coverUrl > 网络 coverUrl > 书架网络封面。
  /// 网盘书的 Book.coverUrl 常为空，但用户在书架设置的自定义封面存在
  /// BookshelfBook.localCoverPath 上，需回查书架。返回 null = 无封面。
  Widget? _coverWidget(
    Book? book, {
    required double width,
    required double height,
    int? decodeWidth,
  }) {
    if (book == null) return null;
    final shelfBook =
        context.read<BookshelfRepository>().getById(book.id);
    var localPath = shelfBook?.localCoverPath;
    var url = book.coverUrl ?? shelfBook?.coverUrl;
    if ((localPath == null || localPath.isEmpty) &&
        url != null &&
        url.startsWith('/')) {
      // 旧数据约定：以 / 开头的 coverUrl 是本地文件路径
      localPath = url;
      url = null;
    }
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        width: width,
        height: height,
        cacheWidth: decodeWidth, // 只解码显示所需尺寸，省内存
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        width: width,
        height: height,
        memCacheWidth: decodeWidth,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return null;
  }

  /// 收起状态的悬浮球（可拖到任意位置）
  Widget _buildBall(BuildContext context, AudioPlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    final cover = _coverWidget(player.currentBook,
        width: ballSize, height: ballSize, decodeWidth: (ballSize * 2).round());
    return Positioned(
      left: _center.dx - ballSize / 2,
      top: _center.dy - ballSize / 2,
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
              if (cover != null) ClipOval(child: cover),
              if (player.isPlaying)
                _waveOverlay(scheme, overCover: cover != null)
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

  /// 球内声波条：4 根竖条按正弦相位差起伏（球本体不位移）。
  /// 有封面时垫一层半透明暗色保证白色声波可读。
  Widget _waveOverlay(ColorScheme scheme, {required bool overCover}) {
    final barColor = scheme.onPrimary.withValues(alpha: 0.95);
    return Container(
      width: ballSize,
      height: ballSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: overCover ? Colors.black.withValues(alpha: 0.45) : null,
      ),
      child: AnimatedBuilder(
        animation: _wave,
        builder: (context, _) {
          final t = _wave.value * 2 * math.pi;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 2.5),
                Container(
                  width: 3,
                  height: 7 + 9 * (0.5 + 0.5 * math.sin(t + i * math.pi / 2)),
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 展开状态：从球的位置弹出小横条（左信息 + 右功能键），不遮罩不挡下层操作。
  /// 点击横条左半（信息区/封面）→ 进入播放页；点收起键或任意位置滑动 → 回球。
  Widget _buildBar(BuildContext context, AudioPlayerService player, Size size) {
    final scheme = Theme.of(context).colorScheme;
    final book = player.currentBook!;
    final chapter = player.currentChapter;
    const barWidth = 340.0;
    const barHeight = 64.0;

    // 横条位置：以球为锚点，整体夹在屏内
    final double barLeft =
        (_center.dx - ballSize / 2 - 4).clamp(0.0, (size.width - barWidth).clamp(0.0, double.infinity));
    var barTop = _center.dy - barHeight / 2;
    barTop = barTop.clamp(8.0, (size.height - barHeight - 16).clamp(8.0, double.infinity));

    return Stack(
      children: [
        Positioned(
          left: barLeft,
          top: barTop,
          // 展开动画：从球的大小/位置放大成横条 + 淡入（以球心为缩放锚点）
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) {
              return Transform.scale(
                scale: 0.55 + 0.45 * t,
                alignment: Alignment(
                  ((_center.dx - (barLeft + barWidth / 2)) /
                          (barWidth / 2))
                      .clamp(-1.0, 1.0),
                  ((_center.dy - (barTop + barHeight / 2)) /
                          (barHeight / 2))
                      .clamp(-1.0, 1.0),
                ),
                child: Opacity(opacity: t, child: child),
              );
            },
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
                              child: _coverWidget(book,
                                      width: 44,
                                      height: 44,
                                      decodeWidth: 88) ??
                                  Container(
                                    color:
                                        scheme.primaryContainer.withValues(alpha: 0.6),
                                    child: Icon(Icons.auto_stories_rounded,
                                        color: scheme.primary),
                                  ),
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
