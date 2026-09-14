import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/progress_repository.dart';
import '../services/audio_player_service.dart';
import '../services/local_import_service.dart';
import '../services/storage_service.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_browser_page.dart';
import 'resource_search_page.dart';
import 'search_page.dart';
import 'shelf_book_detail_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  bool _reordering = false;

  /// 书架布局：0 = 列表视图，其余为每行列数
  int _columns = 3;

  @override
  void initState() {
    super.initState();
    _columns = context.read<StorageService>().getShelfColumns();
  }

  /// 切换书架布局（记住选择）。
  Future<void> _pickLayout() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('书架布局',
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final (value, label, icon) in const [
              (3, '3 列（默认）', Icons.grid_view_rounded),
              (2, '2 列', Icons.grid_view_rounded),
              (4, '4 列', Icons.grid_view_rounded),
              (0, '列表视图', Icons.view_list_rounded),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                trailing:
                    _columns == value ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(ctx, value),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await context.read<StorageService>().saveShelfColumns(picked);
    if (mounted) setState(() => _columns = picked);
  }

  @override
  Widget build(BuildContext context) {
    final bookshelfRepo = context.watch<BookshelfRepository>();
    final books = bookshelfRepo.getAll();

    return Scaffold(
      // 透明背景：露出 HomePage 的渐变，让主界面更通透
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(_reordering ? '拖动排序' : '我的书架'),
        actions: [
          if (_reordering)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: () => setState(() => _reordering = false),
                child: const Text('完成'),
              ),
            )
          else
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded),
              tooltip: '更多',
              onSelected: (value) => _onMenuSelected(context, value),
              itemBuilder: (ctx) => [
                _menuTile('explore', Icons.travel_explore_rounded, '全网搜书'),
                _menuTile('search', Icons.search_rounded, '搜索'),
                _menuTile('drive', Icons.cloud_rounded, '打开网盘'),
                _menuTile('local', Icons.download_rounded, '导入本地音频'),
                _menuTile('layout', Icons.grid_view_rounded, '书架布局'),
                if (books.length > 1)
                  _menuTile('sort', Icons.swap_vert_rounded, '排序书架'),
              ],
            ),
        ],
      ),
      body: books.isEmpty
          ? const _EmptyBookshelf()
          : _reordering
              ? ReorderableListView.builder(
                  // ignore: deprecated_member_use
                  onReorder: (oldIndex, newIndex) =>
                      _onReorder(books, oldIndex, newIndex),
                  itemCount: books.length,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return Padding(
                      key: ValueKey(book.id),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: const Icon(Icons.drag_indicator_rounded),
                          title: Text(book.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${book.chapterCount} 集'),
                        ),
                      ),
                    );
                  },
                )
              : _columns == 0
                  ? ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                      itemCount: books.length,
                      itemBuilder: (context, index) =>
                          _BookshelfItem(book: books[index], compact: true),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _columns,
                        childAspectRatio:
                            _columns == 2 ? 0.72 : (_columns == 4 ? 0.5 : 0.53),
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 18,
                      ),
                      itemCount: books.length,
                      itemBuilder: (context, index) {
                        return _BookshelfItem(book: books[index]);
                      },
                    ),
    );
  }

  /// 拖动排序：立即更新本地列表顺序，完成后持久化。
  void _onReorder(List<BookshelfBook> books, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final book = books.removeAt(oldIndex);
    books.insert(newIndex, book);
    context.read<BookshelfRepository>().reorder(books);
  }

  /// 顶部「更多」菜单项。保持单行紧凑，避免菜单占掉半屏。
  PopupMenuItem<String> _menuTile(
    String value,
    IconData icon,
    String title,
  ) {
    return PopupMenuItem(
      value: value,
      height: 46,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(title, style: const TextStyle(fontSize: 14.5)),
        ],
      ),
    );
  }

  /// 「更多」菜单分发：搜书 / 搜索 / 排序 / 打开网盘 / 导入本地。
  Future<void> _onMenuSelected(BuildContext context, String action) async {
    switch (action) {
      case 'layout':
        await _pickLayout();
        break;
      case 'explore':
        context.pushThrottled(
          MaterialPageRoute(builder: (_) => const ResourceSearchPage()),
        );
        break;
      case 'search':
        context.pushThrottled(
          MaterialPageRoute(builder: (_) => const SearchPage()),
        );
        break;
      case 'sort':
        setState(() => _reordering = true);
        break;
      case 'drive':
        context.pushThrottled(MaterialPageRoute(
          builder: (_) => const DriveBrowserPage(
            initialDrive: DriveType.quark,
          ),
        ));
        break;
      case 'local':
        await _importLocalFile(context);
        break;
    }
  }

  Future<void> _importLocalFile(BuildContext context) async {
    final importService = context.read<LocalImportService>();
    final book = await importService.importAudioFile();
    if (book != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入：${book.title}')),
      );
      // Play the imported book
      final player = context.read<AudioPlayerService>();
      await player.playBook(book);
      if (context.mounted) {
        context.pushPlayerPage();
      }
    }
  }
}

class _EmptyBookshelf extends StatelessWidget {
  const _EmptyBookshelf();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withValues(alpha: 0.18),
                    scheme.tertiary.withValues(alpha: 0.12),
                  ],
                ),
              ),
              child: Icon(
                Icons.library_books_rounded,
                size: 44,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              '书架空空如也',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              '点右上角「⋮」从网盘导入本地音频，\n或用「全网搜书」发现全网资源',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.7,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookshelfItem extends StatelessWidget {
  final BookshelfBook book;

  /// 列表视图：封面在左的横向布局
  final bool compact;

  const _BookshelfItem({required this.book, this.compact = false});

  /// 封面：本地图 → 网络图 → 首字占位图
  Widget _cover({double placeholderFontSize = 44}) {
    if (book.localCoverPath != null) {
      return Image.file(
        File(book.localCoverPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const _PlaceholderCover(title: ''),
      );
    }
    if (book.coverUrl != null) {
      return CachedNetworkImage(
        imageUrl: book.coverUrl!,
        fit: BoxFit.cover,
        errorWidget: (context, url, error) =>
            _PlaceholderCover(title: book.title),
      );
    }
    return _PlaceholderCover(
        title: book.title, fontSize: placeholderFontSize);
  }

  /// Badge describing where the book comes from.
  ({IconData icon, String label, Color color}) _sourceBadge(BuildContext context) {
    if (book.isLocal) {
      return (icon: Icons.download_rounded, label: '本地', color: Colors.teal);
    }
    switch (book.driveType) {
      case DriveType.baidu:
        return (icon: Icons.cloud_rounded, label: '百度', color: Colors.blue);
      case DriveType.quark:
        return (
          icon: Icons.cloud_done_rounded,
          label: '夸克',
          color: Colors.deepPurple
        );
      default:
        return (
          icon: Icons.help_outline_rounded,
          label: '未知',
          color: Theme.of(context).colorScheme.outline
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final progressRepo = context.watch<ProgressRepository>();
    final progress = progressRepo.getProgress(book.id);
    double progressPercent = 0;
    if (progress != null && book.chapterCount > 0) {
      progressPercent = (progress.chapterIndex + 1) / book.chapterCount;
      progressPercent = progressPercent.clamp(0.0, 1.0);
    }
    final badge = _sourceBadge(context);

    if (compact) return _buildCompact(context, progressPercent, badge);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openBook(context),
        onLongPress: () => _showItemActions(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover(),
                  // Source badge
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(badge.icon, size: 11, color: badge.color),
                          const SizedBox(width: 3),
                          Text(
                            badge.label,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (progressPercent > 0)
              LinearProgressIndicator(
                value: progressPercent,
                minHeight: 3,
                backgroundColor: Colors.transparent,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          height: 1.25,
                        ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    progressPercent > 0
                        ? '已听 ${(progressPercent * 100).round()}%'
                        : '${book.chapterCount} 集',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 10.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 长按菜单：进入详情 / 移出书架。
  Future<void> _showItemActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            // 网盘书：进入对应文件夹
            if (book.driveType != null && book.drivePath != null)
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('打开网盘文件夹'),
                subtitle: Text(
                  book.drivePath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('移出书架'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final repo = context.read<BookshelfRepository>();
    final progressRepo = context.read<ProgressRepository>();
    switch (action) {
      case 'open':
        context.pushThrottled(MaterialPageRoute(
          builder: (_) => DriveBrowserPage(
            initialDrive: book.driveType,
            initialPath: book.drivePath,
            initialDirFid: book.driveDirFid,
          ),
        ));
        break;
      case 'remove':
        await repo.remove(book.id);
        // 顺带清理播放进度，避免残留
        await progressRepo.clearProgress(book.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已移出书架：${book.title}'),
              duration: const Duration(milliseconds: 1200),
            ),
          );
        }
        break;
    }
  }

  /// 列表视图：封面在左，标题 / 来源 / 进度在右
  Widget _buildCompact(
    BuildContext context,
    double progressPercent,
    ({IconData icon, String label, Color color}) badge,
  ) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openBook(context),
        onLongPress: () => _showItemActions(context),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 64,
                  child: _cover(placeholderFontSize: 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14.5),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(badge.icon, size: 12, color: badge.color),
                        const SizedBox(width: 3),
                        Text(
                          badge.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: badge.color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${book.chapterCount} 集',
                            style: theme.textTheme.bodySmall),
                        if (progressPercent > 0) ...[
                          const SizedBox(width: 10),
                          Text(
                            '已听 ${(progressPercent * 100).round()}%',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                    if (progressPercent > 0) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progressPercent,
                          minHeight: 3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 点击书籍：进入书籍详情页（信息 + 目录 + 正在播放定位）。
  void _openBook(BuildContext context) {
    context.pushThrottled(MaterialPageRoute(
      builder: (_) => ShelfBookDetailPage(book: book),
    ));
  }
}

/// 首字渐变占位封面（无封面时的默认显示）。
class _PlaceholderCover extends StatelessWidget {
  final String title;

  /// 缩略图场景（列表视图封面）需要更小的字号
  final double fontSize;

  const _PlaceholderCover({required this.title, this.fontSize = 44});

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
      [const Color(0xFF5ee7df), const Color(0xFFb490ca)],
      [const Color(0xFFff9a9e), const Color(0xFFfecfef)],
    ];
    final colors = palette[title.hashCode.abs() % palette.length];
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
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
