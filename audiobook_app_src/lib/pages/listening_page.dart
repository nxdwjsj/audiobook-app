import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bookshelf_book.dart';
import '../models/playback_progress.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/progress_repository.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_page_route.dart';
import '../widgets/book_cover.dart';
import '../widgets/throttled_navigator.dart';
import 'bookshelf_page.dart' show resumeBook, latestPlaybackProgress;
import 'resource_search_page.dart';

/// 「在听」首页（设计规范 §5.2，有声杂志方向）。
///
/// 这一屏回答的问题不是「我有哪些书」，而是**「接着听什么」**。
/// 所以它不是网格，而是一本杂志的目录页：
///   1. 本期主打 —— 最近在听的那本，配期号，占满第一屏；
///   2. 下面两条栏目横滑，一屏露出 2.5 张（露出半张是让人知道可以滑）。
///
/// 与「书架」页的分工：这里负责「继续听」，书架负责「找新书」。
class ListeningPage extends StatelessWidget {
  const ListeningPage({super.key});

  /// 期号：按入库顺序编号，呼应杂志期数。1 → `NO.01`。
  static String issueNumber(List<BookshelfBook> ordered, String bookId) {
    final idx = ordered.indexWhere((b) => b.id == bookId);
    if (idx < 0) return '';
    return 'NO.${(idx + 1).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final repo = context.watch<BookshelfRepository>();
    final books = repo.getAll();

    return Scaffold(
      // 透明：露出 HomePage 的底色，三个 tab 共享同一层背景
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('在听'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: '搜索',
            onPressed: () => _openSearch(context),
          ),
        ],
      ),
      body: books.isEmpty
          ? Center(
              child: Text(
                '书架还是空的\n先从网盘里挑一本开始听',
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(color: AppInk.tertiary(isDark)),
              ),
            )
          : _body(context, books, isDark),
    );
  }

  Widget _body(BuildContext context, List<BookshelfBook> books, bool isDark) {
    final progressRepo = context.watch<ProgressRepository>();
    final all = progressRepo.getAll();

    // 继续听：有收听记录的，最近听过的排前面
    final byId = {for (final b in books) b.id: b};
    final recent = List<PlaybackProgress>.of(all)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final listening = recent
        .map((p) => byId[p.bookId])
        .whereType<BookshelfBook>()
        .toList();

    // 新入库：按加入时间倒序
    final newest = List<BookshelfBook>.of(books)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

    // 主打卡：优先最近在听的，没有就取最新入库的
    final hero = latestPlaybackProgress(all) != null &&
            listening.isNotEmpty
        ? listening.first
        : newest.first;

    // 期号按入库顺序（老书 NO.01）
    final byAdded = List<BookshelfBook>.of(books)
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      children: [
        _Hero(
          book: hero,
          issue: issueNumber(byAdded, hero.id),
          progress: progressRepo.getProgress(hero.id),
          isDark: isDark,
        ),
        if (listening.length > 1)
          _Rail(
            title: '继续收听',
            books: listening.skip(1).take(8).toList(),
            progressOf: (id) => progressRepo.getProgress(id),
            isDark: isDark,
          ),
        _Rail(
          title: '新入库',
          books: newest.take(8).toList(),
          progressOf: (id) => progressRepo.getProgress(id),
          isDark: isDark,
        ),
      ],
    );
  }

  void _openSearch(BuildContext context) {
    // 与书架页一致：Navigator 1.0 + 节流封装 + 统一页面转场
    context.pushThrottled(
      AppPageRoute(builder: (_) => const ResourceSearchPage()),
    );
  }
}

/// 本期主打：大封面 + 期号 + 书名 + 演播 + 继续收听。
class _Hero extends StatelessWidget {
  const _Hero({
    required this.book,
    required this.issue,
    required this.progress,
    required this.isDark,
  });

  final BookshelfBook book;
  final String issue;
  final PlaybackProgress? progress;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final chapterNo = p == null ? 0 : p.chapterIndex + 1;
    final total = book.chapterCount > 0 ? book.chapterCount : (p?.chapterCount ?? 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 大封面直接开播 —— 首页最该能一键完成的动作
          GestureDetector(
            onTap: () => resumeBook(context, book),
            child: SizedBox(
              width: 132,
              height: 176,
              child: BookCover(
                title: book.title,
                author: book.author,
                customImagePath: book.localCoverPath,
                networkCoverUrl: book.coverUrl,
                memCacheWidth: 500,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (issue.isNotEmpty)
                  Text(
                    issue,
                    style: AppType.micro.copyWith(
                      color: AppInk.tertiary(isDark),
                      letterSpacing: 1.6,
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                GestureDetector(
                  onTap: () => resumeBook(context, book),
                  child: Text(
                    book.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.display.copyWith(
                      color: AppInk.primary(isDark),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  book.author == null || book.author!.isEmpty
                      ? '未知演播'
                      : '${book.author} 演播',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(color: AppInk.secondary(isDark)),
                ),
                if (total > 0) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    chapterNo > 0
                        ? '第 $chapterNo 章 · 共 $total 章'
                        : '共 $total 章',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppType.caption.copyWith(color: AppInk.tertiary(isDark)),
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    _RoundPlay(onTap: () => resumeBook(context, book)),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '继续收听',
                            style: AppType.body.copyWith(
                              fontWeight: FontWeight.w500,
                              color: AppInk.primary(isDark),
                            ),
                          ),
                          Text(
                            chapterNo > 0 ? '第 $chapterNo 章' : '从头开始',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.micro
                                .copyWith(color: AppInk.tertiary(isDark)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 墨色实心圆播放按钮。
class _RoundPlay extends StatelessWidget {
  const _RoundPlay({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppInk.primary(isDark),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.play_arrow_rounded,
          size: 24,
          color: AppInk.onSolid(isDark),
        ),
      ),
    );
  }
}

/// 栏目：标题 + 横向滚动的一排书。
class _Rail extends StatelessWidget {
  const _Rail({
    required this.title,
    required this.books,
    required this.progressOf,
    required this.isDark,
  });

  final String title;
  final List<BookshelfBook> books;
  final PlaybackProgress? Function(String bookId) progressOf;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
          child: Text(
            title,
            style: AppType.body.copyWith(
              fontWeight: FontWeight.w500,
              color: AppInk.primary(isDark),
            ),
          ),
        ),
        SizedBox(
          height: 158,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (context, i) => _RailItem(
              book: books[i],
              progress: progressOf(books[i].id),
              isDark: isDark,
            ),
          ),
        ),
      ],
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.book,
    required this.progress,
    required this.isDark,
  });

  final BookshelfBook book;
  final PlaybackProgress? progress;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final total = book.chapterCount > 0 ? book.chapterCount : 0;
    final done = progress == null || total == 0
        ? 0.0
        : ((progress!.chapterIndex + 1) / total).clamp(0.0, 1.0);

    return SizedBox(
      width: 82,
      child: GestureDetector(
        onTap: () => resumeBook(context, book),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 82,
              height: 109,
              child: BookCover(
                title: book.title,
                author: book.author,
                customImagePath: book.localCoverPath,
                networkCoverUrl: book.coverUrl,
                progress: done > 0 ? done : null,
                memCacheWidth: 300,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(
                fontWeight: FontWeight.w500,
                color: AppInk.primary(isDark),
              ),
            ),
            Text(
              done > 0
                  ? '第 ${progress!.chapterIndex + 1} 章 · 共 $total 章'
                  : (book.author ?? '共 $total 章'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.micro.copyWith(color: AppInk.tertiary(isDark)),
            ),
          ],
        ),
      ),
    );
  }
}
