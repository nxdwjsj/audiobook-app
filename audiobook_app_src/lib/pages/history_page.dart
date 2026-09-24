import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/bookshelf_book.dart';
import '../models/listen_session.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/listen_session_repository.dart';
import '../services/audio_player_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/frosted_glass.dart';
import '../widgets/throttled_navigator.dart';
import '../models/book.dart';

/// 收听历史页：会话制记录——每次手动点播一条记录，
/// 自动连播只更新最后一条。能看到“几点开始、听到第几章”。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sessionRepo = context.watch<ListenSessionRepository>();
    final shelfRepo = context.watch<BookshelfRepository>();
    final sessions = sessionRepo.getAll();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('收听历史'),
        actions: [
          if (sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空历史',
              onPressed: () => _confirmClear(context, sessions.length),
            ),
        ],
      ),
      body: sessions.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 72,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '还没有收听记录',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final s = sessions[index];
                return _SessionTile(
                  session: s,
                  shelfBook: shelfRepo.getById(s.bookId),
                );
              },
            ),
    );
  }

  Future<void> _confirmClear(BuildContext context, int count) async {
    final confirmed = await showFrostedBottomSheet<bool>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Text('清空收听历史',
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text('将删除全部 $count 条会话记录（不影响书架和播放进度）',
                style: Theme.of(ctx).textTheme.bodyMedium),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('清空'),
              ),
              const SizedBox(width: 24),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<ListenSessionRepository>().clearAll();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清空收听历史')),
      );
    }
  }
}

class _SessionTile extends StatelessWidget {
  final ListenSession session;
  final BookshelfBook? shelfBook;

  const _SessionTile({required this.session, required this.shelfBook});

  @override
  Widget build(BuildContext context) {
    final title = shelfBook?.title.isNotEmpty == true
        ? shelfBook!.title
        : session.bookTitle;
    final chapterNo = session.chapterIndex + 1;
    final total = shelfBook?.chapterCount ?? session.chapterCount ?? 0;
    final percent = total > 0 ? (chapterNo / total * 100).round() : null;
    final chapterTitle = session.chapterTitle;
    final isCurrent = _isCurrentlyPlaying(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete_outline_rounded,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      onDismissed: (_) =>
          context.read<ListenSessionRepository>().delete(session.id),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .primary
                .withValues(alpha: isCurrent ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: isCurrent ? 0.4 : 0.22),
            ),
          ),
          child: Icon(
            isCurrent
                ? Icons.graphic_eq_rounded
                : Icons.headphones_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 原为 fontSize 15 + w500：15 不在字阶里。标题级是 17，正文是 14 ——
          // 列表项属正文级，取 body。
          style: AppType.body.copyWith(
            fontWeight: FontWeight.w500,
            color: AppInk.primary(isDark),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.xs),
          child: Text(
            '第 $chapterNo 章${chapterTitle != null ? ' · $chapterTitle' : ''}\n'
            '${_fmtStart(session.startedAt)} · ${_fmtDuration(session.positionSeconds)}'
            '${percent != null ? '（$percent%）' : ''}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            // 原为 fontSize 13（不在字阶里）→ caption 12 + 次文字色，
            // 与标题形成明确层级而不是靠 1px 的差别。
            style: AppType.caption.copyWith(color: AppInk.secondary(isDark)),
          ),
        ),
        trailing: isCurrent
            ? Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                decoration: BoxDecoration(
                  color: AppInk.accent(isDark).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  '正在播放',
                  // 原为 fontSize 12 + w600：w600 违反「只用 400/500」的硬约束。
                  style: AppType.micro.copyWith(
                    fontWeight: FontWeight.w500,
                    color: AppInk.accent(isDark),
                  ),
                ),
              )
            : const Icon(Icons.play_circle_outline_rounded),
        onTap: () => _continuePlaying(context),
      ),
    );
  }

  bool _isCurrentlyPlaying(BuildContext context) {
    final player = context.read<AudioPlayerService>();
    if (!player.hasBook || player.currentBook!.id != session.bookId) {
      return false;
    }
    // 同一本书的其它集不算：只有正在播的这一集才标「正在播放」，
    // 否则同书的多条历史会全部亮起
    return player.currentChapterIndex == session.chapterIndex;
  }

  String _fmtStart(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${t.month}/${t.day} $hm';
  }

  String _fmtDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    if (m < 60) return '$m 分钟';
    return '${m ~/ 60} 小时 ${m % 60} 分';
  }

  void _continuePlaying(BuildContext context) {
    final player = context.read<AudioPlayerService>();
    final position = Duration(seconds: session.positionSeconds);
    // 不在书架中：无论是否正在播放都不能进详情页（shelfBook 为 null）
    if (shelfBook == null) {
      // 正在播放这本书：至少还能进播放页
      if (player.hasBook && player.currentBook!.id == session.bookId) {
        context.pushPlayerPage();
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${session.bookTitle}」已不在书架中，无法继续播放')),
        );
      }
      return;
    }
    // 已点开本书：要跳到这条记录对应的那一集与进度，
    // 不能只把播放页推出来（否则集数和时间都对不上）
    if (player.hasBook && player.currentBook!.id == session.bookId) {
      if (player.currentChapterIndex != session.chapterIndex) {
        player.jumpToChapter(session.chapterIndex, startPosition: position);
      } else if (position > Duration.zero &&
          (player.position - position).abs() > const Duration(seconds: 5)) {
        player.seek(position);
      }
      context.pushPlayerPage();
      return;
    }
    // 换书了：通过播放器服务点播这本书，并从 session 记录的章节与位置续播
    player.playBook(
      _buildPlayBook(),
      startChapter: session.chapterIndex,
      startPosition: position,
    );
    // 直接进播放页开始听
    if (context.mounted) context.pushPlayerPage();
  }

  Book _buildPlayBook() {
    return Book(
      id: shelfBook!.id,
      title: shelfBook!.title,
      author: shelfBook!.author,
      description: shelfBook!.description,
      coverUrl: shelfBook!.localCoverPath ?? shelfBook!.coverUrl,
      chapters: shelfBook!.chapters ?? [],
    );
  }
}
