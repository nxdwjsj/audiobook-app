import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/bookshelf_repository.dart';
import '../services/audio_player_service.dart';
import '../theme/app_tokens.dart';
import 'book_cover.dart';
import 'throttled_navigator.dart';

/// 常驻迷你播放条（设计规范 §5.7，有声杂志方向）。
///
/// 挂在 HomePage 的 bottomNavigationBar 槽位上，取代旧的全局悬浮球：
/// - 只在首页四栏目可见 —— 进入播放页 / 详情页等推送路由时整个首页被
///   覆盖（offstage），本条随之隐藏。旧悬浮球挂在全局 Overlay 之上、
///   盖住所有路由，才需要 `PlayerPage.isShown` 这类额外判断；现在
///   「在哪个层级显示」直接由组件树位置决定。
/// - 无正在播放的书时整条收起（高度动画到 0，不留空条占位）。
/// - 顶边一条 2px 进度线显示当前章节进度（强调色）。
/// - 信息区（封面 + 书名 + 章节）点击进播放页；右侧播放/暂停 + 下一章。
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<AudioPlayerService>();
    final hasBook = player.hasBook && player.currentBook != null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: hasBook
          ? _Bar(player: player)
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.player});

  final AudioPlayerService player;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final book = player.currentBook!;
    final chapter = player.currentChapter;

    final duration = player.duration;
    final progress = (duration != null && duration.inMilliseconds > 0)
        ? (player.position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
        : 0.0;

    // 网盘书的 Book.coverUrl 常为空，但用户设置的自定义封面在书架记录上，
    // 回查一次（内存缓存命中，代价可忽略）。
    final shelfBook = context.read<BookshelfRepository>().getById(book.id);

    return Material(
      color: AppInk.surface(isDark),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶边进度线：章节进度，强调色
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: Container(height: 2, color: AppInk.accent(isDark)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  // ---- 信息区：进播放页 ----
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => context.pushPlayerPage(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 42,
                              height: 56,
                              child: BookCover(
                                title: book.title,
                                author: book.author,
                                customImagePath: shelfBook?.localCoverPath,
                                networkCoverUrl:
                                    book.coverUrl ?? shelfBook?.coverUrl,
                                elevated: false,
                                memCacheWidth: 120,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    book.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppType.caption.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: AppInk.primary(isDark),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  // 失败态：迷你栏是「不在播放页」时唯一能看到
                                  // 播放状态的地方，后台连播失败必须在这里可见
                                  // （规范 §5.7 失败态：图标与文案走警示色）。
                                  if (player.lastError != null)
                                    Row(
                                      children: [
                                        Icon(Icons.error_outline_rounded,
                                            size: 14,
                                            color: AppInk.warning(isDark)),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            player.lastError!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppType.micro.copyWith(
                                              color: AppInk.warning(isDark),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    Text(
                                      chapter != null
                                          ? '${player.currentChapterIndex + 1}. ${chapter.title}'
                                          : '第 ${player.currentChapterIndex + 1} 集',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppType.micro.copyWith(
                                        color: AppInk.tertiary(isDark),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // ---- 播放/暂停：墨色实心圆 ----
                  _RoundToggle(player: player),
                  // 失败时「下一章」没有意义 → 换成「重试」；
                  // 正在重试则显示转圈，避免连点。
                  if (player.lastError != null && !player.retrying)
                    IconButton(
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: 24,
                        color: AppInk.warning(isDark),
                      ),
                      tooltip: '重试',
                      onPressed: player.retryCurrent,
                    )
                  else if (player.retrying)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppInk.warning(isDark),
                        ),
                      ),
                    )
                  else
                    IconButton(
                      icon: Icon(
                        Icons.skip_next_rounded,
                        size: 24,
                        color: AppInk.secondary(isDark),
                      ),
                      tooltip: '下一章',
                      onPressed: player.nextChapter,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundToggle extends StatelessWidget {
  const _RoundToggle({required this.player});

  final AudioPlayerService player;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: player.playPause,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppInk.primary(isDark),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 22,
          color: AppInk.onSolid(isDark),
        ),
      ),
    );
  }
}
