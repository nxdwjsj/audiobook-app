import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/drive_item.dart';
import '../models/playback_progress.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/progress_repository.dart';
import '../services/audio_player_service.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_browser_page.dart';
import 'edit_book_info_page.dart';

/// 书架书籍详情页：封面 + 信息 + 完整目录 + 正在播放章节高亮。
/// 网盘书/本地书统一入口，目录不再需要去网盘翻文件夹。
class ShelfBookDetailPage extends StatefulWidget {
  final BookshelfBook book;

  const ShelfBookDetailPage({super.key, required this.book});

  @override
  State<ShelfBookDetailPage> createState() => _ShelfBookDetailPageState();
}

class _ShelfBookDetailPageState extends State<ShelfBookDetailPage> {
  final _scrollController = ScrollController();
  bool _scrolledToPlaying = false;

  /// 目录排序：false = 正序（第 1 集在上），true = 倒序（最新在上）。
  bool _descending = false;

  /// 实时从书架读取最新数据（编辑信息、进度缓存变化后立即同步）。
  BookshelfBook get _book =>
      context.read<BookshelfRepository>().getById(widget.book.id) ??
      widget.book;

  @override
  void initState() {
    super.initState();
    // 章节列表渲染后定位到正在播放的章节
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 定位到正在播放章节（首次进入自动执行；工具条按钮可强制触发）。
  void _scrollToPlaying({bool force = false}) {
    if (!force && (_scrolledToPlaying || !mounted)) return;
    final player = context.read<AudioPlayerService>();
    if (!player.hasBook || player.currentBook!.id != widget.book.id) return;
    final chapters = _chapters;
    if (chapters.isEmpty) return;
    final index = player.currentChapterIndex;
    if (!force && index <= 0) {
      _scrolledToPlaying = true;
      return;
    }
    // 估算行高定位（ListTile dense + subtitle 约 64px）
    final row = _descending ? chapters.length - 1 - index : index;
    final target = (row * 64.0).clamp(0.0, double.maxFinite);
    _scrolledToPlaying = true;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }


  List<Chapter> get _chapters => _book.chapters ?? const [];

  /// 渲染用章节列表（含排序）。
  List<Chapter> get _displayChapters =>
      _descending ? _chapters.reversed.toList() : _chapters;

  @override
  Widget build(BuildContext context) {
    // watch 书架数据：编辑信息/加入移出后本页立即同步
    context.watch<BookshelfRepository>();
    final player = context.watch<AudioPlayerService>();
    final progress = context.watch<ProgressRepository>().getProgress(_book.id);
    final isCurrent = player.hasBook && player.currentBook!.id == _book.id;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // 编辑信息（封面/作者/简介）
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑信息',
            onPressed: () => context.pushThrottled(
              MaterialPageRoute(
                builder: (_) => EditBookInfoPage(bookId: _book.id),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _handleMenuAction(context, v),
            itemBuilder: (ctx) => [
              if (_book.driveType != null && _book.drivePath != null)
                const PopupMenuItem(
                  value: 'open_folder',
                  child: Text('打开网盘文件夹'),
                ),
              const PopupMenuItem(
                value: 'remove',
                child: Text('移出书架'),
              ),
            ],
          ),
        ],
      ),
      // 顶栏透明 + 背景取渐变首色，body 用同色渐变衔接
      backgroundColor: AppTheme.pageTopColor(Theme.of(context).brightness),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTheme.pageGradient(Theme.of(context).brightness),
        ),
        child: _buildBody(context, isCurrent, player, progress),
      ),
      bottomNavigationBar: _buildBottomBar(context, isCurrent, player, progress),
    );
  }

  Widget _buildBody(BuildContext context, bool isCurrent,
      AudioPlayerService player, PlaybackProgress? progress) {
    final chapters = _displayChapters;
    // 头部信息（封面/简介/统计）+ 章节列表放在同一个懒加载列表里，
    // 3384 章也只构建屏幕内可见的行，不卡顿。
    const headerCount = 3; // header + stats + 目录标题
    return Stack(
      children: [
        ListView.builder(
          controller: _scrollController,
          // 底部留出浮动按钮组的空间，避免最后一行被遮挡
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: headerCount + chapters.length,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context),
                  if (_book.description != null && _book.description!.isNotEmpty)
                    _buildDescription(context),
                ],
              );
            }
            if (index == 1) return _buildStatsRow(context, progress);
            if (index == 2) return _buildChapterTitle(context, chapters.length);
            final chapterIndex = _descending
                ? _chapters.length - 1 - (index - headerCount)
                : index - headerCount;
            final chapter = chapters[index - headerCount];
            final isPlayingChapter =
                isCurrent && chapterIndex == player.currentChapterIndex;
            return ListTile(
              dense: true,
              leading: isPlayingChapter
                  ? Icon(Icons.graphic_eq_rounded,
                      color: Theme.of(context).colorScheme.primary)
                  : Text('${chapterIndex + 1}'),
              title: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight:
                      isPlayingChapter ? FontWeight.bold : FontWeight.normal,
                  color: isPlayingChapter
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              trailing: isPlayingChapter
                  ? Text(
                      '正在播放',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : null,
              onTap: () => _playChapter(context, chapterIndex),
            );
          },
        ),
        // 浮动目录工具条：回顶部 / 定位正在播放 / 正倒序切换，列表任意位置可用
        Positioned(
          right: 16,
          bottom: 16,
          child: _buildFloatingChapterToolbar(context, chapters.length),
        ),
      ],
    );
  }

  /// 目录标题行（仅标题，按钮在浮动工具条上）。
  Widget _buildChapterTitle(BuildContext context, int chapterCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        chapterCount == 0 ? '暂无章节信息' : '目录（$chapterCount 集）',
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  /// 浮动目录工具条：回顶部 / 定位正在播放 / 正倒序切换，悬浮于列表右下角。
  Widget _buildFloatingChapterToolbar(BuildContext context, int chapterCount) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.vertical_align_top_rounded),
              tooltip: '回到顶部',
              onPressed: () => _scrollController.hasClients
                  ? _scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    )
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.my_location_rounded),
              tooltip: '定位到正在播放',
              onPressed: () => _scrollToPlaying(force: true),
            ),
            IconButton(
              icon: Icon(_descending
                  ? Icons.south_rounded
                  : Icons.north_rounded),
              tooltip: _descending ? '当前：最新在前，点击改为第 1 集在前' : '当前：第 1 集在前，点击改为最新在前',
              onPressed: () {
                setState(() => _descending = !_descending);
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(0);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCover(context),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _book.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  _book.author ?? '未知作者',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_book.chapterCount} 集 · ${_sourceLabel()}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _sourceLabel() {
    if (_book.isLocal) return '本地导入';
    switch (_book.driveType) {
      case DriveType.quark:
        return '夸克网盘';
      case DriveType.baidu:
        return '百度网盘';
      default:
        return '未知来源';
    }
  }

  Widget _buildCover(BuildContext context) {
    Widget? cover;
    if (_book.localCoverPath != null) {
      cover = Image.file(File(_book.localCoverPath!),
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
    } else if (_book.coverUrl != null) {
      cover = Image.network(
        _book.coverUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 120,
        height: 170,
        child: cover ?? _PlaceholderCover(title: _book.title),
      ),
    );
  }

  Widget _buildDescription(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        _book.description!,
        style: Theme.of(context).textTheme.bodyMedium,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildStatsRow(BuildContext context, PlaybackProgress? progress) {
    String stats;
    if (progress != null && _book.chapterCount > 0) {
      final percent =
          ((progress.chapterIndex + 1) / _book.chapterCount * 100).round();
      stats = '已听到第 ${progress.chapterIndex + 1} 集（$percent%）';
    } else {
      stats = '尚未收听';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          avatar: const Icon(Icons.headphones_rounded, size: 18),
          label: Text(stats),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, bool isCurrent,
      AudioPlayerService player, PlaybackProgress? progress) {
    // 正在播放本书：底部显示迷你播放栏，可在详情页直接暂停/切章/进入播放页。
    if (isCurrent) {
      return const SafeArea(child: MiniPlayer());
    }
    final startChapter = progress?.chapterIndex ?? 0;
    final positionSeconds = progress?.positionSeconds ?? 0;
    final label = progress != null ? '继续播放' : '开始播放';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: () => _resumePlay(context, startChapter, positionSeconds),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(
            progress != null
                ? '$label · 第 ${startChapter + 1} 集 ${_formatPosition(positionSeconds)}'
                : label,
          ),
        ),
      ),
    );
  }

  String _formatPosition(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _handleMenuAction(BuildContext context, String action) async {
    switch (action) {
      case 'open_folder':
        context.pushThrottled(MaterialPageRoute(
          builder: (_) => DriveBrowserPage(
            initialDrive: _book.driveType,
            initialPath: _book.drivePath,
            initialDirFid: _book.driveDirFid,
          ),
        ));
        break;
      case 'remove':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('移出书架'),
            content: Text('确定将「${_book.title}」移出书架？收听进度将一并清除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('移出'),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        final repo = context.read<BookshelfRepository>();
        final progressRepo = context.read<ProgressRepository>();
        await repo.remove(_book.id);
        await progressRepo.clearProgress(_book.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已移出书架：${_book.title}'),
              duration: const Duration(milliseconds: 1200),
            ),
          );
          Navigator.pop(context);
        }
        break;
    }
  }

  // --- 播放逻辑 ---

  Book _toPlayBook() {
    return Book(
      id: _book.id,
      title: _book.title,
      author: _book.author,
      description: _book.description,
      coverUrl: _book.localCoverPath ?? _book.coverUrl,
      chapters: _chapters,
    );
  }

  Future<void> _playChapter(BuildContext context, int index) async {
    // 只切章播放，不跳转播放页：列表原地高亮为“正在播放”，
    // 想看播放器可点底部迷你栏手动进入。
    final player = context.read<AudioPlayerService>();
    if (player.hasBook && player.currentBook!.id == _book.id) {
      await player.jumpToChapter(index);
    } else {
      await player.playBook(_toPlayBook(), startChapter: index);
    }
  }

  Future<void> _resumePlay(
      BuildContext context, int chapterIndex, int positionSeconds) async {
    final player = context.read<AudioPlayerService>();
    // 已在播放本书 → 保持原地，不打断
    if (player.hasBook && player.currentBook!.id == _book.id) {
      return;
    }
    await player.playBook(
      _toPlayBook(),
      startChapter: chapterIndex,
      startPosition: Duration(seconds: positionSeconds),
    );
  }
}

/// 首字渐变占位封面（无封面时的默认显示）。
class _PlaceholderCover extends StatelessWidget {
  final String title;

  const _PlaceholderCover({required this.title});

  @override
  Widget build(BuildContext context) {
    // 按书名哈希取色，同书恒定，多书之间有色差
    final palette = [
      [const Color(0xFF667eea), const Color(0xFF764ba2)],
      [const Color(0xFFf093fb), const Color(0xFFf5576c)],
      [const Color(0xFF4facfe), const Color(0xFF00f2fe)],
      [const Color(0xFF43e97b), const Color(0xFF38f9d7)],
      [const Color(0xFFfa709a), const Color(0xFFfee140)],
      [const Color(0xFF30cfd0), const Color(0xFF330867)],
      [const Color(0xFFa8edea), const Color(0xFFfed6e3)],
      [const Color(0xFFff9a9e), const Color(0xFFfad0c4)],
    ];
    final colors =
        palette[title.hashCode.abs() % palette.length];
    final ch = title.trim().isEmpty ? '书' : title.trim().characters.first;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Center(
        child: Text(
          ch,
          style: const TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
