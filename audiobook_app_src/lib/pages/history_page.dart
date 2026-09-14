import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/bookshelf_book.dart';
import '../models/listen_session.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/listen_session_repository.dart';
import '../services/audio_player_service.dart';
import '../widgets/throttled_navigator.dart';
import 'shelf_book_detail_page.dart';
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
          : ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空收听历史'),
        content: Text('将删除全部 $count 条会话记录（不影响书架和播放进度）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
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
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            isCurrent
                ? Icons.graphic_eq_rounded
                : Icons.headphones_rounded,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '第 $chapterNo 章${chapterTitle != null ? ' · $chapterTitle' : ''}\n'
          '${_fmtStart(session.startedAt)}开始 · 已听 ${_fmtDuration(session.positionSeconds)}'
          '${percent != null ? '（$percent%）' : ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: isCurrent
            ? Text(
                '正在播放',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : const Icon(Icons.play_circle_outline_rounded),
        onTap: () => _continuePlaying(context),
      ),
    );
  }

  bool _isCurrentlyPlaying(BuildContext context) {
    final player = context.read<AudioPlayerService>();
    return player.hasBook && player.currentBook!.id == session.bookId;
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
    // 正在播放当前书：直接进入详情页查看
    final player = context.read<AudioPlayerService>();
    if (player.hasBook && player.currentBook!.id == session.bookId) {
      context.pushThrottled(MaterialPageRoute(
        builder: (_) => ShelfBookDetailPage(book: shelfBook!),
      ));
      return;
    }
    // 不在书架中或换书了：直接从这里播放，不打断其他收听（按手册要求「不需要在线功能、只需要网盘」）
    if (shelfBook == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${session.bookTitle}」已不在书架中，无法继续播放')),
        );
      }
      return;
    }
    // 通过播放器服务点播这本书并从 session 章节开始
    context.read<AudioPlayerService>().playBook(_buildPlayBook(), startChapter: session.chapterIndex);
    // 播放后自动进入详情页
    if (context.mounted) {
      context.pushThrottled(MaterialPageRoute(
        builder: (_) => ShelfBookDetailPage(book: shelfBook!),
      ));
    }
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
