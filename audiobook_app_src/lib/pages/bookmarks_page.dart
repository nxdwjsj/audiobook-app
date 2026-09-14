import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/bookmark.dart';
import '../repositories/bookmark_repository.dart';
import '../services/audio_player_service.dart';

class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final bookmarkRepo = context.watch<BookmarkRepository>();
    final bookmarks = bookmarkRepo.getAll();

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书签'),
      ),
      body: bookmarks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bookmark_border_rounded,
                    size: 80,
                    color:
                        Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '还没有书签',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '播放时点击书签图标来添加',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: bookmarks.length,
              itemBuilder: (context, index) {
                final bookmark = bookmarks[index];
                return Dismissible(
                  key: ValueKey(bookmark.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) {
                    bookmarkRepo.remove(bookmark.id);
                  },
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text('${bookmark.chapterIndex + 1}'),
                    ),
                    title: Text(bookmark.chapterTitle),
                    subtitle: Text(
                      '${bookmark.bookTitle} · ${_formatDuration(bookmark.position)}',
                    ),
                    trailing: const Icon(Icons.play_arrow_rounded),
                    onTap: () => _jumpToBookmark(context, bookmark),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _jumpToBookmark(BuildContext context, Bookmark bookmark) async {
    // 跳转书签需要书架中仍有此书
    final player = context.read<AudioPlayerService>();
    // If the same book is already loaded, just seek
    if (player.currentBook?.id == bookmark.bookId) {
      await player.jumpToChapter(bookmark.chapterIndex);
      await Future.delayed(const Duration(milliseconds: 300));
      await player.seek(Duration(seconds: bookmark.positionSeconds));
    } else {
      // Book must be in bookshelf to resume; online books are no longer supported
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书签对应的书籍已不在书架中')),
        );
      }
    }
  }

  String _formatDuration(Duration duration) {
    final m = duration.inMinutes;
    final s = duration.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
