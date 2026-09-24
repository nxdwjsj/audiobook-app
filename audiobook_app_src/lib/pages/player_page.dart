import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import 'drive_login_page.dart';
import '../services/audio_player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_page_route.dart';
import '../widgets/frosted_glass.dart';
import '../theme/app_tokens.dart';
import '../widgets/throttled_navigator.dart';

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  /// 播放页是否已在导航栈顶（全局唯一，防止重复堆叠）。
  /// 由 PlayerPageScope 包裹维护。
  static bool get isShown => _shownCount > 0;
  static int _shownCount = 0;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();

    // 通知权限被拒时提示一次：通知栏/锁屏不会有播放控制。
    // 「只提示一次」的标志放在 service 上——本页是无状态组件，存不了实例字段。
    if (player.notificationBlocked && !player.notificationNoticeShown) {
      player.notificationNoticeShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('通知权限未开启，通知栏不会显示播放控制'),
          duration: Duration(seconds: 6),
          action: SnackBarAction(label: '去开启', onPressed: openAppSettings),
        ));
      });
    }

    return _PlayerPageScope(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('正在播放'),
          actions: [
            IconButton(
              icon: Icon(
                Icons.fast_forward_rounded,
                // 已设置时高亮，和定时按钮的表现保持一致
                color: (player.skipIntroSeconds > 0 ||
                        player.skipOutroSeconds > 0)
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: '跳过片头片尾',
              onPressed: () => _showSkipSheet(context, player),
            ),
            IconButton(
              icon: const Icon(Icons.list_rounded),
              tooltip: '章节列表',
              onPressed: player.hasBook ? () => _showChapters(context) : null,
            ),
          ],
        ),
        // 顶栏透明 + 背景取渐变首色，body 用同色渐变衔接，视觉上是一整片
        backgroundColor: AppTheme.pageTopColor(Theme.of(context).brightness),
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: AppTheme.pageGradient(Theme.of(context).brightness),
          ),
          child: player.hasBook
              ? _buildPlayer(context, player)
              : const _NoBookView(),
        ),
      ),
    );
  }

  Widget _buildPlayer(BuildContext context, AudioPlayerService player) {
    final book = player.currentBook!;
    final chapter = player.currentChapter;

    // LayoutBuilder + SingleChildScrollView avoids overflow on short screens
    // (e.g. when the error banner appears or in landscape).
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    // Cover
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.42,
                        maxWidth: constraints.maxHeight * 0.42,
                      ),
                      child: _buildCover(context, book.coverUrl),
                    ),
                    const SizedBox(height: 24),
                    // Title & author
                    Text(
                      book.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chapter?.title ?? '',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 20),
                    // 自动重试提示：失败后静默重试期间给用户一个反馈，
                    // 否则界面看起来像卡死（尤其校园网/CDN 域名解析抖动时）
                    if (player.retrying)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '网络不稳定，正在自动重试…',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Error banner
                    if (player.lastError != null && !player.retrying)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.error_outline_rounded,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onErrorContainer),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      player.lastError!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onErrorContainer),
                                    ),
                                  ),
                                ],
                              ),
                              // 登录失效时给一个可操作的出口：否则用户只能
                              // 自己猜「是不是要重贴一次 Cookie」。
                              if (player.cloudAuthExpired) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: () => context.pushThrottled(
                                      AppPageRoute(
                                        builder: (_) => const DriveLoginPage(),
                                      ),
                                    ),
                                    icon: const Icon(Icons.login, size: 18),
                                    label: const Text('去重新连接'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Theme.of(context)
                                          .colorScheme
                                          .onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    // Progress bar
                    _buildProgressBar(context, player),
                    const SizedBox(height: 16),
                    // Controls
                    _buildControls(context, player),
                    const SizedBox(height: 16),
                    // Speed & sleep timer
                    _buildExtraControls(context, player),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCover(BuildContext context, String? coverUrl) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(
          aspectRatio: 1,
          child: _coverWidget(context, coverUrl),
        ),
      ),
    );
  }

  /// 本地封面（编辑信息选的图）用 Image.file，网络封面用缓存图。
  /// 封面显示约 220px，限制解码尺寸避免大图全尺寸解码浪费内存。
  Widget _coverWidget(BuildContext context, String? coverUrl) {
    if (coverUrl == null) return _coverPlaceholder(context);
    if (coverUrl.startsWith('/')) {
      return Image.file(File(coverUrl),
          fit: BoxFit.cover,
          cacheWidth: 600,
          errorBuilder: (_, __, ___) => _coverPlaceholder(context));
    }
    return CachedNetworkImage(
      imageUrl: coverUrl,
      fit: BoxFit.cover,
      memCacheWidth: 600,
      errorWidget: (context, url, error) => _coverPlaceholder(context),
    );
  }

  Widget _coverPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.book_rounded,
        size: 100,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, AudioPlayerService player) {
    final position = player.position;
    final duration = player.duration ?? Duration.zero;
    final value = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return Column(
      children: [
        // 使用SliderTheme优化滑块性能
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4.0,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16.0),
          ),
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: duration.inMilliseconds > 0
                ? (v) {
                    final newPos =
                        Duration(milliseconds: (v * duration.inMilliseconds).toInt());
                    player.seek(newPos);
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(position)),
              Text(_formatDuration(duration)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls(BuildContext context, AudioPlayerService player) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GlassSurface(
          borderRadius: 24,
          child: IconButton(
            icon: const Icon(Icons.skip_previous_rounded),
            iconSize: 32,
            color: scheme.primary,
            tooltip: '上一章',
            onPressed: player.previousChapter,
          ),
        ),
        const SizedBox(width: 24),
        FloatingActionButton.large(
          onPressed: player.playPause,
          child: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 48,
          ),
        ),
        const SizedBox(width: 24),
        GlassSurface(
          borderRadius: 24,
          child: IconButton(
            icon: const Icon(Icons.skip_next_rounded),
            iconSize: 32,
            color: scheme.primary,
            tooltip: '下一章',
            onPressed: player.nextChapter,
          ),
        ),
      ],
    );
  }

  /// 高频操作区。
  ///
  /// 曾把倍速与定时展开成整排芯片，用户反馈**不需要展开** —— 改回紧凑按钮，
  /// 点开才是选项。保留三个入口：倍速 / 定时 / 章节（章节此前只能从别处进）。
  Widget _buildExtraControls(BuildContext context, AudioPlayerService player) {
    final total = player.currentBook?.chapters.length ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _compactButton(
          context,
          icon: Icons.speed_rounded,
          label: '${player.speed.toStringAsFixed(1)}x',
          active: player.speed != 1.0,
          onTap: () => _showSpeedDialog(context, player),
        ),
        _compactButton(
          context,
          icon: player.hasSleepTimer
              ? Icons.timer_rounded
              : Icons.timer_outlined,
          label: player.hasSleepTimer
              ? _formatDuration(player.sleepRemaining ?? Duration.zero)
              : '定时',
          active: player.hasSleepTimer,
          onTap: () => _showSleepTimerDialog(context, player),
        ),
        _compactButton(
          context,
          icon: Icons.list_rounded,
          label: total > 0
              ? '${player.currentChapterIndex + 1}/$total'
              : '章节',
          onTap: () => _showChapters(context),
        ),
      ],
    );
  }

  /// 紧凑按钮：图标 + 文字，点开才是具体选项；[active] 时反白表示已生效。
  Widget _compactButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool active = false,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? AppInk.primary(isDark) : Colors.transparent,
          border: active
              ? null
              : Border.all(color: AppInk.hairline(isDark), width: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? AppInk.onSolid(isDark) : AppInk.secondary(isDark),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppType.micro.copyWith(
                color:
                    active ? AppInk.onSolid(isDark) : AppInk.secondary(isDark),
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 倍速：常用档位 + 非常用档位，走弹窗（不铺在页面上）。
  void _showSpeedDialog(BuildContext context, AudioPlayerService player) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    showFrostedBottomSheet(
      context: context,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.8,
        expand: false,
        builder: (ctx, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('播放速度',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: speeds
                    .map((s) => ChoiceChip(
                          label: Text('${s.toStringAsFixed(s % 1 == 0 ? 0 : 2)}x'),
                          selected: s == player.speed,
                          onSelected: (_) {
                            player.setSpeed(s);
                            Navigator.pop(ctx);
                          },
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerDialog(BuildContext context, AudioPlayerService player) {
    final durations = [
      const Duration(minutes: 15),
      const Duration(minutes: 30),
      const Duration(minutes: 45),
      const Duration(minutes: 60),
      const Duration(minutes: 90),
    ];
    showFrostedBottomSheet(
      context: context,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.8,
        expand: false,
        builder: (ctx, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('定时关闭',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: durations
                    .map((d) => ChoiceChip(
                          label: Text('${d.inMinutes} 分钟'),
                          selected: false,
                          onSelected: (_) {
                            player.setSleepTimer(d);
                            Navigator.pop(ctx);
                          },
                        ))
                    .toList(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('自定义时间'),
              onTap: () {
                Navigator.pop(ctx);
                _showCustomTimerDialog(context, player);
              },
            ),
            if (player.hasSleepTimer)
              ListTile(
                leading: const Icon(Icons.timer_off_rounded),
                title: const Text('取消定时'),
                onTap: () {
                  player.cancelSleepTimer();
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 设置跳过片头 / 片尾秒数（0 = 不跳过），底部半屏面板。
  /// 片头：每次开始播放章节时自动跳到该秒数。
  /// 片尾：播到距结尾不足该秒数时自动进入下一章。
  Future<void> _showSkipSheet(
    BuildContext context,
    AudioPlayerService player,
  ) async {
    // 用局部变量接住输入，控制器交给 TextFormField 自己管理：
    // 避免外部 TextEditingController 在面板退场动画期间被提前释放。
    var intro = player.skipIntroSeconds;
    var outro = player.skipOutroSeconds;

    await showFrostedBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 下拉条：提示这是一块可下滑关闭的面板，而不是弹窗
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('跳过片头 / 片尾',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '仅对《${player.currentBook?.title ?? ''}》生效。'
                  '章节本身比设定的跳过时长还短时不会跳过，避免连跳整本书。',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: intro > 0 ? '$intro' : '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '跳过片头（秒）',
                    hintText: '0 = 不跳过，例如 30',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => intro = int.tryParse(v.trim()) ?? 0,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: outro > 0 ? '$outro' : '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '跳过片尾（秒）',
                    hintText: '0 = 不跳过，例如 20',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => outro = int.tryParse(v.trim()) ?? 0,
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    // 面板关闭后再改状态，避免退场动画期间触发上层重建
                    player.setSkipIntroSeconds(intro < 0 ? 0 : intro);
                    player.setSkipOutroSeconds(outro < 0 ? 0 : outro);
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCustomTimerDialog(BuildContext context, AudioPlayerService player) {
    final controller = TextEditingController(text: '30');
    showFrostedBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text('自定义定时（分钟）',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '输入分钟数，如 45'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final minutes = int.tryParse(controller.text.trim());
                    if (minutes != null && minutes > 0) {
                      player.setSleepTimer(Duration(minutes: minutes));
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text('确定'),
                ),
                const SizedBox(width: 24),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ).whenComplete(() => controller.dispose());
  }

  void _showChapters(BuildContext context) {
    final player = context.read<AudioPlayerService>();
    final book = player.currentBook!;
    showFrostedBottomSheet(
      context: context,
      builder: (ctx) => _ChapterSheet(book: book, player: player),
    );
  }

}

String _formatDuration(Duration duration) {
  if (duration.inMinutes < 60) {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
  final h = duration.inHours;
  final m = duration.inMinutes % 60;
  final s = duration.inSeconds % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 章节面板（播放页）：分页浏览 + 打开即定位到正在播放的章节。
///
/// 每页 [pageSize] 集，横排页码 chips（如 1-300、301-600）；
/// 打开时自动切到当前播放章节所在页，并用 ensureVisible 精确滚到该行
/// （不再用估算行高，长章节名/短章节名混排也能定位准确）。
class _ChapterSheet extends StatefulWidget {
  final Book book;
  final AudioPlayerService player;

  const _ChapterSheet({required this.book, required this.player});

  @override
  State<_ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<_ChapterSheet> {
  static const int pageSize = 300;

  /// 章节行高：dense 双行 ListTile 实为 64。
  /// 列表显式指定 itemExtent（同一数值），「滚到第 N 行」的偏移因此可被
  /// 精确计算——原先按 52 估算低估了约 20%，几百行后偏差累积到上万像素，
  /// 目标行始终进不了懒加载的构建范围，表现为「打开目录定位不准」。
  static const double _baseRowExtent = 64.0;

  final ScrollController _listController = ScrollController();
  final ScrollController _chipController = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};

  late int _page = widget.book.chapters.isEmpty
      ? 0
      : (widget.player.currentChapterIndex.clamp(
              0, widget.book.chapters.length - 1) / pageSize)
          .floor();

  @override
  void initState() {
    super.initState();
    // 打开面板即定位到当前播放章节
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrent());
  }

  @override
  void dispose() {
    _listController.dispose();
    _chipController.dispose();
    super.dispose();
  }

  int get _pageCount =>
      (widget.book.chapters.length / pageSize).ceil().clamp(1, 99999);

  int get _startIndex => _page * pageSize;

  int get _endIndex =>
      ((_page + 1) * pageSize).clamp(0, widget.book.chapters.length);

  /// 当前播放章节在第几页（用于「定位」按钮）。
  int get _playingPage => widget.book.chapters.isEmpty
      ? 0
      : (widget.player.currentChapterIndex.clamp(
              0, widget.book.chapters.length - 1) / pageSize)
          .floor();

  /// 系统字体放大时行高跟着变大，否则文字会被 itemExtent 裁掉。
  double get _rowExtent {
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.4);
    return _baseRowExtent * scale;
  }

  void _locateCurrent() {
    _locateCurrentInner(retriesLeft: 12);
  }

  /// 延迟重试：面板入场动画期间列表视口尚未展开（maxScrollExtent 很小），
  /// 此时 jumpTo 会被 clamp 到顶部，必须等动画结束再滚才准。
  void _retryLocate(int retriesLeft) {
    Future.delayed(
      const Duration(milliseconds: 50),
      () => _locateCurrentInner(retriesLeft: retriesLeft),
    );
  }

  void _locateCurrentInner({required int retriesLeft}) {
    if (!mounted) return;
    if (widget.book.chapters.isEmpty) return;
    final index = widget.player.currentChapterIndex;
    if (index < 0 || index >= widget.book.chapters.length) return;
    // 章节不在当前页 → 先切页，等行构建出来再滚
    if (_playingPage != _page) {
      setState(() => _page = _playingPage);
      _retryLocate(retriesLeft);
      return;
    }
    final ctx = _rowKeys[index]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.4, // 目标行停在视口 40% 处，便于看到上下文
      );
      return;
    }
    // 目标行还没被构建（懒加载列表只构建视口附近）：先按精确行高把列表滚到
    // 目标上方，让目标行进入构建范围，随后 ensureVisible 精确对齐
    if (retriesLeft <= 0) return;
    if (!_listController.hasClients) {
      _retryLocate(retriesLeft - 1);
      return;
    }
    final offset = (index - _startIndex) * _rowExtent - 120;
    _listController
        .jumpTo(offset.clamp(0.0, _listController.position.maxScrollExtent));
    _retryLocate(retriesLeft - 1);
  }

  void _switchPage(int page) {
    setState(() => _page = page.clamp(0, _pageCount - 1));
    // 切页后回到列表顶部
    if (_listController.hasClients) _listController.jumpTo(0);
    // 让选中的 chip 滚进可视区（1500 集 = 5 页，通常都可见，保险起见）
    final chipCtx = _chipKeys[page]?.currentContext;
    if (chipCtx != null) {
      Scrollable.ensureVisible(chipCtx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.5);
    }
  }

  final Map<int, GlobalKey> _chipKeys = {};

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final book = widget.book;
    final scheme = Theme.of(context).colorScheme;
    final start = _startIndex;
    final end = _endIndex;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, _) => Column(
        children: [
          // 标题 + 定位按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '目录（${book.chapters.length} 集）',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.my_location_rounded),
                  tooltip: '定位到正在播放',
                  onPressed: _locateCurrent,
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          // 分页 chips：1-300 / 301-600 / …
          if (_pageCount > 1)
            SizedBox(
              height: 44,
              child: ListView.builder(
                controller: _chipController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _pageCount,
                itemBuilder: (ctx, i) {
                  final s = i * pageSize + 1;
                  final e = ((i + 1) * pageSize).clamp(0, book.chapters.length);
                  final selected = i == _page;
                  return Padding(
                    key: _chipKeys[i] ??= GlobalKey(),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text('$s-$e'),
                      selected: selected,
                      onSelected: (_) => _switchPage(i),
                    ),
                  );
                },
              ),
            ),
          // 当前页章节列表
          Expanded(
            child: ListView.builder(
              controller: _listController,
              // 固定行高：让「滚到第 N 行」的偏移可精确计算（定位准）
              itemExtent: _rowExtent,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: end - start,
              itemBuilder: (ctx, row) {
                final index = start + row;
                final chapter = book.chapters[index];
                final isCurrent = index == player.currentChapterIndex;
                return ListTile(
                  key: _rowKeys[index] ??= GlobalKey(),
                  dense: true,
                  leading: isCurrent
                      ? Icon(Icons.play_arrow_rounded, color: scheme.primary)
                      : SizedBox(
                          width: 28,
                          child: Text('${index + 1}',
                              textAlign: TextAlign.right,
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                        ),
                  title: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isCurrent ? FontWeight.w500 : null,
                      color: isCurrent ? scheme.primary : null,
                    ),
                  ),
                  subtitle: Text(_formatDuration(chapter.duration)),
                  onTap: () {
                    player.jumpToChapter(index);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 维护 PlayerPage 的在栈计数：构建时 +1，销毁时 -1。
/// PlayerPage.isShown 据此判断是否已有播放页。
class _PlayerPageScope extends StatefulWidget {
  final Widget child;

  const _PlayerPageScope({required this.child});

  @override
  State<_PlayerPageScope> createState() => _PlayerPageScopeState();
}

class _PlayerPageScopeState extends State<_PlayerPageScope> {
  @override
  void initState() {
    super.initState();
    PlayerPage._shownCount++;
  }

  @override
  void dispose() {
    PlayerPage._shownCount--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NoBookView extends StatelessWidget {
  const _NoBookView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.headphones_rounded,
            size: 80,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有在播放',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '从书架或搜索中选择一本书开始收听',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
