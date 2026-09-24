import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../widgets/app_page_route.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/book_source_repository.dart';
import '../repositories/progress_repository.dart';
import '../services/audio_player_service.dart';
import '../services/book_source/online_book_hit.dart';
import '../services/local_import_service.dart';
import '../services/storage_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/book_cover.dart';
import '../widgets/frosted_glass.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_browser_page.dart';
import 'resource_search_page.dart';
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
    final picked = await showFrostedBottomSheet<int>(
      context: context,
      builder: (ctx) => Column(
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
            IconButton(
              icon: const Icon(Icons.more_horiz_rounded),
              tooltip: '更多',
              onPressed: () => _showMoreMenu(context, books.length),
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
                        // 两列时封面按规范走 3:4 竖版（书是竖的），
                        // 加上下方两行文字约为宽度的 0.66 倍高。
                        childAspectRatio:
                            _columns == 2 ? 0.66 : (_columns == 4 ? 0.5 : 0.53),
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 20,
                      ),
                      itemCount: books.length,
                      itemBuilder: (context, index) {
                        return _BookshelfItem(book: books[index]);
                      },
                      // 添加缓存扩展以提高滚动性能
                      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                    ),
    );
  }

  /// 右上角「更多」菜单：雾白毛玻璃 BottomSheet。
  Future<void> _showMoreMenu(BuildContext context, int bookCount) async {
    final action = await showFrostedBottomSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _menuTile('search', Icons.search_rounded, '搜索'),
          _menuTile('drive', Icons.cloud_rounded, '打开网盘'),
          _menuTile('local', Icons.download_rounded, '导入本地音频'),
          _menuTile('layout', Icons.grid_view_rounded, '书架布局'),
          _menuTile('motion', Icons.animation_rounded, '减弱动效'),
          if (bookCount > 1)
            _menuTile('sort', Icons.swap_vert_rounded, '排序书架'),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (action == null || !context.mounted) return;
    await _onMenuSelected(context, action);
  }

  /// 菜单项（BottomSheet 版）：图标 + 简洁文字，无分割线，靠留白区分。
  Widget _menuTile(
    String value,
    IconData icon,
    String title,
  ) {
    return ListTile(
      leading: Icon(icon, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      onTap: () => Navigator.pop(context, value),
    );
  }

  /// 拖动排序：立即更新本地列表顺序，完成后持久化。
  void _onReorder(List<BookshelfBook> books, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final book = books.removeAt(oldIndex);
    books.insert(newIndex, book);
    context.read<BookshelfRepository>().reorder(books);
  }

  /// 「更多」菜单分发：搜书 / 搜索 / 排序 / 打开网盘 / 导入本地。
  Future<void> _onMenuSelected(BuildContext context, String action) async {
    switch (action) {
      case 'layout':
        await _pickLayout();
        break;
      case 'search':
        context.pushThrottled(
          AppPageRoute(builder: (_) => const ResourceSearchPage()),
        );
        break;
      case 'sort':
        setState(() => _reordering = true);
        break;
      case 'drive':
        context.pushThrottled(AppPageRoute(
          builder: (_) => const DriveBrowserPage(
            initialDrive: DriveType.quark,
          ),
        ));
        break;
      case 'local':
        await _importLocalFile(context);
        break;
      case 'motion':
        await _toggleReduceMotion(context);
        break;
    }
  }

  /// 「减弱动效」开关：低端设备把全局时长压缩 45%、曲线退化为线性。
  Future<void> _toggleReduceMotion(BuildContext context) async {
    final storage = context.read<StorageService>();
    final next = !storage.getReduceMotion();
    await storage.saveReduceMotion(next);
    AppMotion.lowPerformance = next;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(next ? '已开启减弱动效' : '已恢复完整动效')),
    );
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

class _BookshelfItem extends StatefulWidget {
  final BookshelfBook book;

  /// 列表视图：封面在左的横向布局
  final bool compact;

  const _BookshelfItem({required this.book, this.compact = false});

  @override
  State<_BookshelfItem> createState() => _BookshelfItemState();
}

class _BookshelfItemState extends State<_BookshelfItem> {
  BookshelfBook get book => widget.book;

  /// 封面：本地图 → 网络图 → 首字占位图
  /// 统一走 [BookCover]（设计规范 §4）：自选图 → 网络图 → 生成封面，三级降级。
  ///
  /// 来源角标与底部进度条也由 BookCover 负责，页面不再自绘 ——
  /// 原先页面里那层彩色角标（黑底 + 彩色图标）已按规范移除。
  /// 解码尺寸统一限制在 300px（书架封面显示约 100-150dp × dpr2-3），省内存。
  Widget _cover({
    required ({IconData icon, String label, Color color}) badge,
    double progress = 0,
  }) {
    return BookCover(
      title: book.title,
      author: book.author,
      customImagePath: book.localCoverPath,
      networkCoverUrl: book.coverUrl,
      sourceLabel: badge.label,
      progress: progress,
    );
  }

  /// Badge describing where the book comes from.
  ({IconData icon, String label, Color color}) _sourceBadge(BuildContext context) {
    if (book.isLocal) {
      return (icon: Icons.download_rounded, label: '本地', color: Colors.teal);
    }
    // 在线书源：id 是 online_{书源id}_{路径}，解析出书源名显示
    if (book.id.startsWith('online_')) {
      final repo = context.read<BookSourceRepository>();
      final sourceId = onlineSourceIdOfBookId(
          book.id, repo.all.map((s) => s.id));
      final name =
          repo.all.where((s) => s.id == sourceId).firstOrNull?.name;
      if (name != null && name.isNotEmpty) {
        return (
          icon: Icons.public_rounded,
          label: name,
          color: Colors.orange
        );
      }
      return (
        icon: Icons.public_rounded,
        label: '在线',
        color: Colors.orange
      );
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

  /// 封面上的快速播放按钮：点击直接续播，不进详情页。
  /// 无进度时从头播放。
  Widget _quickPlayButton(BuildContext context, {bool small = false}) {
    final scheme = Theme.of(context).colorScheme;
    final size = small ? 26.0 : 32.0;
    return GestureDetector(
      // 内层手势赢得竞技场，点击不会透传到外层 InkWell（进详情页）
      behavior: HitTestBehavior.opaque,
      onTap: () => _quickPlay(context),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primary.withValues(alpha: 0.92),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          size: size,
          color: scheme.onPrimary,
        ),
      ),
    );
  }

  /// 快速播放：直接续播（有进度从进度处播，无进度从头播），
  /// 不跳转播放页 —— 浮球会同步展示播放状态。
  Future<void> _quickPlay(BuildContext context) async {
    final player = context.read<AudioPlayerService>();
    if (player.hasBook && player.currentBook!.id == book.id) {
      // 正在播这本书：直接进播放页
      if (context.mounted) context.pushPlayerPage();
      return;
    }
    // 章节已拆到独立 box（PERF-01）：getAll() 返回的书不含章节，这里按需取
    // （命中内存 LRU，代价可忽略）。
    final chapters = context.read<BookshelfRepository>().getChapters(book.id);
    if (chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这本书没有章节信息，请先进入详情页刷新')),
      );
      return;
    }
    final playBook = Book(
      id: book.id,
      title: book.title,
      author: book.author,
      description: book.description,
      coverUrl: book.localCoverPath ?? book.coverUrl,
      chapters: chapters,
    );
    try {
      await player.resumeFromProgress(playBook);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败：$e')),
        );
      }
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

    if (widget.compact) return _buildCompact(context, progressPercent, badge);

    return GlassSurface(
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
                  _cover(badge: badge, progress: progressPercent),
                  // 快速播放按钮：封面右下角
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: _quickPlayButton(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    progressPercent > 0 && progress != null
                        ? '第 ${progress.chapterIndex + 1} 章 · 共 ${book.chapterCount} 章'
                        : '共 ${book.chapterCount} 章',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro.copyWith(
                      color: AppInk.secondary(Theme.of(context).brightness == Brightness.dark),
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
    final action = await showFrostedBottomSheet<String>(
      context: context,
      builder: (ctx) => Column(
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
    );
    if (action == null || !context.mounted) return;
    final repo = context.read<BookshelfRepository>();
    final progressRepo = context.read<ProgressRepository>();
    switch (action) {
      case 'open':
        context.pushThrottled(AppPageRoute(
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
    return GlassSurface(
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
                  child: _cover(badge: badge, progress: progressPercent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14.5),
                          ),
                        ),
                        // 快速播放按钮：标题右侧
                        _quickPlayButton(context, small: true),
                      ],
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
    context.pushThrottled(AppPageRoute(
      builder: (_) => ShelfBookDetailPage(book: book),
    ));
  }
}

/// 首字渐变占位封面（无封面时的默认显示）。
// 旧的自绘占位封面（随机渐变 + 单个汉字 + title.hashCode 取色）已删除。
// 统一由 widgets/book_cover.dart 的 BookCover 负责（设计规范 §4）：
// 出版色板 + 竖排书名 + 稳定哈希，且自带角标与进度条。
