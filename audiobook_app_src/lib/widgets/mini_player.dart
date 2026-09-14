import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_player_service.dart';
import 'throttled_navigator.dart';

/// Mini player bar shown at the bottom of the app when audio is playing.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();

    if (!player.hasBook) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final book = player.currentBook!;
    final chapter = player.currentChapter;
    final duration = player.duration ?? Duration.zero;
    final progress = duration.inMilliseconds > 0
        ? player.position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
        child: InkWell(
          onTap: () {
            context.pushPlayerPage();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 2.5,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: book.coverUrl != null
                            ? CachedNetworkImage(
                                imageUrl: book.coverUrl!,
                                fit: BoxFit.cover,
                                errorWidget: (context, url, error) => Container(
                                  color: scheme.surfaceContainerHighest,
                                  child: Icon(Icons.book_rounded,
                                      color: scheme.onSurfaceVariant),
                                ),
                              )
                            : Container(
                                color: scheme.surfaceContainerHighest,
                                child: Icon(Icons.book_rounded,
                                    color: scheme.onSurfaceVariant),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            chapter?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 11.5,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded),
                      tooltip: '上一章',
                      onPressed: player.previousChapter,
                    ),
                    IconButton(
                      icon: Icon(
                        player.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                      ),
                      iconSize: 38,
                      color: scheme.primary,
                      tooltip: player.isPlaying ? '暂停' : '播放',
                      onPressed: player.playPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded),
                      tooltip: '下一章',
                      onPressed: player.nextChapter,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}