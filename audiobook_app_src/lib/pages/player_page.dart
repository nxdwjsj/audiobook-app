import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_player_service.dart';

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  /// 播放页是否已在导航栈顶（全局唯一，防止重复堆叠）。
  /// 由 PlayerPageScope 包裹维护。
  static bool get isShown => _shownCount > 0;
  static int _shownCount = 0;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();

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
              onPressed: () => _showSkipDialog(context, player),
            ),
            IconButton(
              icon: const Icon(Icons.list_rounded),
              tooltip: '章节列表',
              onPressed: player.hasBook ? () => _showChapters(context) : null,
            ),
          ],
        ),
        body: player.hasBook ? _buildPlayer(context, player) : const _NoBookView(),
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
                            fontWeight: FontWeight.bold,
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
                    // Error banner
                    if (player.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline_rounded,
                                  color:
                                      Theme.of(context).colorScheme.onErrorContainer),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 1,
        child: _coverWidget(context, coverUrl),
      ),
    );
  }

  /// 本地封面（编辑信息选的图）用 Image.file，网络封面用缓存图。
  Widget _coverWidget(BuildContext context, String? coverUrl) {
    if (coverUrl == null) return _coverPlaceholder(context);
    if (coverUrl.startsWith('/')) {
      return Image.file(File(coverUrl),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _coverPlaceholder(context));
    }
    return CachedNetworkImage(
      imageUrl: coverUrl,
      fit: BoxFit.cover,
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
        Slider(
          value: value.clamp(0.0, 1.0),
          onChanged: duration.inMilliseconds > 0
              ? (v) {
                  final newPos =
                      Duration(milliseconds: (v * duration.inMilliseconds).toInt());
                  player.seek(newPos);
                }
              : null,
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 36,
          tooltip: '上一章',
          onPressed: player.previousChapter,
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
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 36,
          tooltip: '下一章',
          onPressed: player.nextChapter,
        ),
      ],
    );
  }

  Widget _buildExtraControls(BuildContext context, AudioPlayerService player) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Speed control
        TextButton.icon(
          icon: const Icon(Icons.speed_rounded),
          label: Text('${player.speed.toStringAsFixed(1)}x'),
          onPressed: () => _showSpeedDialog(context, player),
        ),
        // Sleep timer
        TextButton.icon(
          icon: Icon(
            player.hasSleepTimer ? Icons.timer_rounded : Icons.timer_outlined,
            color: player.hasSleepTimer
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          label: Text(player.hasSleepTimer
              ? _formatDuration(player.sleepRemaining ?? Duration.zero)
              : '定时'),
          onPressed: () => _showSleepTimerDialog(context, player),
        ),
      ],
    );
  }

  void _showSpeedDialog(BuildContext context, AudioPlayerService player) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    showModalBottomSheet(
      context: context,
      // 可滚动 + 限制高度：选项多时不再溢出（黄黑条纹）
      isScrollControlled: true,
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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

  /// 设置跳过片头 / 片尾秒数（0 = 不跳过）。
  /// 片头：每次开始播放章节时自动跳到该秒数。
  /// 片尾：播到距结尾不足该秒数时自动进入下一章。
  Future<void> _showSkipDialog(
    BuildContext context,
    AudioPlayerService player,
  ) async {
    final introController = TextEditingController(
      text: player.skipIntroSeconds > 0 ? '${player.skipIntroSeconds}' : '',
    );
    final outroController = TextEditingController(
      text: player.skipOutroSeconds > 0 ? '${player.skipOutroSeconds}' : '',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳过片头 / 片尾'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: introController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '跳过片头（秒）',
                hintText: '0 = 不跳过，例如 30',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: outroController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '跳过片尾（秒）',
                hintText: '0 = 不跳过，例如 20',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '章节本身比设定的跳过时长还短时不会跳过，避免连跳整本书。',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final intro = int.tryParse(introController.text.trim()) ?? 0;
              final outro = int.tryParse(outroController.text.trim()) ?? 0;
              player.setSkipIntroSeconds(intro < 0 ? 0 : intro);
              player.setSkipOutroSeconds(outro < 0 ? 0 : outro);
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    introController.dispose();
    outroController.dispose();
  }

  void _showCustomTimerDialog(BuildContext context, AudioPlayerService player) {
    final controller = TextEditingController(text: '30');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义定时（分钟）'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '输入分钟数，如 45'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
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
        ],
      ),
    );
  }

  void _showChapters(BuildContext context) {
    final player = context.read<AudioPlayerService>();
    final book = player.currentBook!;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => ListView.builder(
          controller: scrollController,
          itemCount: book.chapters.length,
          itemBuilder: (ctx, index) {
            final chapter = book.chapters[index];
            final isCurrent = index == player.currentChapterIndex;
            return ListTile(
              leading: isCurrent
                  ? Icon(Icons.play_arrow_rounded,
                      color: Theme.of(context).colorScheme.primary)
                  : Text('${index + 1}'),
              title: Text(
                chapter.title,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : null,
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
    );
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
