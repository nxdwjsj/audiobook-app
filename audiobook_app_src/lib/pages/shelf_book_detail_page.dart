import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../widgets/app_page_route.dart';
import 'package:provider/provider.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/drive_item.dart';
import '../models/playback_progress.dart';
import '../repositories/bookshelf_repository.dart';
import '../repositories/book_source_repository.dart';
import '../repositories/progress_repository.dart';
import '../services/audio_player_service.dart';
import '../services/book_source/online_book_hit.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/book_cover.dart';
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

  /// 目录分页：每页 300 集，长书不用滑几千行。
  static const int _pageSize = 300;
  int _page = 0;

  /// 行 key：分页 + 精确定位都靠它做 ensureVisible。
  final Map<int, GlobalKey> _chapterRowKeys = {};

  late final BookshelfRepository _shelfRepo;

  /// 本页书籍数据缓存。
  ///
  /// storage 里存的是 JSON Map，每次 getById 都要重建整本书（含几千集章节），
  /// 而本页在滑动中会反复读取它（分页条每页一个 chip、倒序时每行版本号、
  /// 头部信息）。所以只在书架数据真正变化时重解析一次，其余时候复用，
  /// 否则滑动时每次都做一遍全量反序列化，表现为明显卡顿。
  late BookshelfBook _cachedBook;

  /// 实时从书架读取最新数据（编辑信息、加入移出后立即同步）。
  BookshelfBook get _book => _cachedBook;

  @override
  void initState() {
    super.initState();
    _shelfRepo = context.read<BookshelfRepository>();
    _cachedBook = _readBook();
    _shelfRepo.addListener(_onShelfChanged);
    // 章节列表渲染后定位到正在播放的章节
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
  }

  BookshelfBook _readBook() =>
      _shelfRepo.getById(widget.book.id) ?? widget.book;

  void _onShelfChanged() {
    if (!mounted) return;
    setState(() => _cachedBook = _readBook());
  }

  @override
  void dispose() {
    _shelfRepo.removeListener(_onShelfChanged);
    _scrollController.dispose();
    super.dispose();
  }

  int get _pageCount => (_chapters.length / _pageSize).ceil().clamp(1, 99999);

  List<Chapter> get _chapters => _cachedBook.chapters ?? const [];

  /// 当前页要显示的章节（已应用排序）。
  List<Chapter> get _displayChapters {
    final all = _descending ? _chapters.reversed.toList() : _chapters;
    final start = (_page * _pageSize).clamp(0, all.length);
    final end = ((_page + 1) * _pageSize).clamp(0, all.length);
    return all.sublist(start, end);
  }

  /// 当前播放章节（或进度章节）落在第几页。
  int get _playingPageIndex {
    final player = context.read<AudioPlayerService>();
    var index = 0;
    if (player.hasBook && player.currentBook!.id == _book.id) {
      index = player.currentChapterIndex;
    } else {
      final progress = context.read<ProgressRepository>().getProgress(_book.id);
      index = progress?.chapterIndex ?? 0;
    }
    if (index < 0) index = 0;
    if (_chapters.isNotEmpty && index >= _chapters.length) {
      index = _chapters.length - 1;
    }
    return (index / _pageSize).floor();
  }

  /// 定位到正在播放章节（首次进入自动执行；浮动按钮可强制触发）。
  /// 分页视图：切到所在页 → 若目标行未构建则按估算行高先滚到附近（让行进入构建区）
  /// → ensureVisible 精确对齐（不依赖估算行高做最终定位）。
  void _scrollToPlaying({bool force = false}) {
    if (!mounted) return;
    if (!force && _scrolledToPlaying) return;
    final player = context.read<AudioPlayerService>();
    if (!player.hasBook || player.currentBook!.id != widget.book.id) {
      return;
    }
    final index = player.currentChapterIndex;
    _scrolledToPlaying = true;
    if (index < 0 || _chapters.isEmpty || index >= _chapters.length) return;

    final targetPage = (index / _pageSize).floor();
    void locateRow({int retriesLeft = 8, double extra = 0}) {
      if (!mounted) return;
      final key = _chapterRowKeys[index];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.4,
        );
        return;
      }
      // 行还没被懒加载构建：按行高把列表滚到目标附近，行进入构建范围后
      // 再精确对齐。行高 48 = dense 单行 ListTile（标题 + trailing）；
      // header 4 行高度差得远，粗略按 320 估，估算偏低时逐轮向下微调
      // （cacheExtent 2000 兜底，邻近行都能被构建）。
      if (retriesLeft <= 0 || !_scrollController.hasClients) return;
      final offset =
          320 + (index - _page * _pageSize) * 48.0 + extra - 120;
      _scrollController.jumpTo(
          offset.clamp(0.0, _scrollController.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => locateRow(retriesLeft: retriesLeft - 1, extra: extra + 150));
    }

    if (targetPage != _page) {
      setState(() => _page = targetPage);
      // 切页后行还没构建，等一帧再定位
      WidgetsBinding.instance.addPostFrameCallback((_) => locateRow());
    } else {
      locateRow();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅「当前播放的书 + 章节号」：播放服务每秒都会推送位置变化，
    // 直接 watch 会让整页（含几百行目录）跟着每秒重建一次。
    // 书架数据的变化由 initState 里的 listener 单独处理（见 _onShelfChanged）。
    context.select<AudioPlayerService, (String?, int)>(
      (p) => (p.currentBook?.id, p.currentChapterIndex),
    );
    final player = context.read<AudioPlayerService>();
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
              AppPageRoute(
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
    // 行内高频用到的值先取好，避免每行都做一次 InheritedWidget 查找
    final primary = Theme.of(context).colorScheme.primary;
    const headerCount = 4; // header + stats + 目录标题 + 分页条
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
                  if (_book.description != null &&
                      _book.description!.isNotEmpty)
                    _buildDescription(context),
                ],
              );
            }
            if (index == 1) return _buildStatsRow(context, progress);
            if (index == 2) return _buildChapterTitle(context, _chapters.length);
            if (index == 3) return _buildPageSelector(context);
            final rowIndex = index - headerCount;
            // 当前页数据已应用排序，映射回真实章节下标
            final pageStart = _page * _pageSize;
            final chapterIndex = _descending
                ? _chapters.length - 1 - (pageStart + rowIndex)
                : pageStart + rowIndex;
            final chapter = chapters[rowIndex];
            final isPlayingChapter =
                isCurrent && chapterIndex == player.currentChapterIndex;
            return ListTile(
              key: _chapterRowKeys[chapterIndex] ??= GlobalKey(),
              dense: true,
              leading: isPlayingChapter
                  ? Icon(Icons.graphic_eq_rounded, color: primary)
                  : Text('${chapterIndex + 1}'),
              title: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight:
                      isPlayingChapter ? FontWeight.bold : FontWeight.normal,
                  color: isPlayingChapter ? primary : null,
                ),
              ),
              trailing: isPlayingChapter
                  ? Text(
                      '正在播放',
                      style: TextStyle(
                        fontSize: 11,
                        color: primary,
                      ),
                    )
                  : null,
              onTap: () => _playChapter(context, chapterIndex),
            );
          },
          // 添加缓存扩展以提高滚动性能
          scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
        ),
        // 聚合浮动小圆钮：点击展开竖排菜单（回顶/定位/排序），可拖动并记忆位置
        _ChapterFab(
          scrollController: _scrollController,
          descending: _descending,
          onLocate: () => _scrollToPlaying(force: true),
          onToggleOrder: () {
            setState(() => _descending = !_descending);
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(0);
            }
          },
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

  /// 分页条：1-300 / 301-600 / …，点击切换当前显示的章节区间。
  Widget _buildPageSelector(BuildContext context) {
    if (_pageCount <= 1) return const SizedBox.shrink();
    // 每个 chip 都要判断「是不是在播放页」，这里整体算一次就够
    final playingPage = _playingPageIndex;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _pageCount,
        itemBuilder: (ctx, i) {
          final s = i * _pageSize + 1;
          final e = ((i + 1) * _pageSize).clamp(0, _chapters.length);
          final selected = i == _page;
          final isPlayingPage = i == playingPage;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(
                '$s-$e${isPlayingPage && !selected ? ' ⏵' : ''}',
              ),
              selected: selected,
              onSelected: (_) => setState(() {
                _page = i;
                _scrolledToPlaying = true; // 手动切页后不再自动定位
              }),
            ),
          );
        },
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
    // 在线书源：id 是 online_{书源id}_{路径}，从中解析书源名
    if (_book.id.startsWith('online_')) {
      final repo = context.read<BookSourceRepository>();
      final sourceId = onlineSourceIdOfBookId(
          _book.id, repo.all.map((s) => s.id));
      if (sourceId.isNotEmpty) {
        final name =
            repo.all.where((s) => s.id == sourceId).firstOrNull?.name;
        if (name != null && name.isNotEmpty) return '来自$name';
      }
      return '在线书源';
    }
    switch (_book.driveType) {
      case DriveType.quark:
        return '夸克网盘';
      case DriveType.baidu:
        return '百度网盘';
      default:
        return '未知来源';
    }
  }

  /// 详情页封面统一走 [BookCover]（设计规范 §4、§5.1）。
  ///
  /// 此前这里是「有自选图就画、有网络图就画、都没有就画渐变占位」的三份分支，
  /// 与书架页各写一套 —— 两处的降级行为、取色算法、圆角都不一致。
  /// 现在全部收敛到 BookCover，封面观感在书架与详情之间保持连续。
  Widget _buildCover(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 170,
      child: BookCover(
        title: _book.title,
        author: _book.author,
        customImagePath: _book.localCoverPath,
        networkCoverUrl: _book.coverUrl,
        memCacheWidth: 600,
        borderRadius: BorderRadius.circular(12),
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
    // 底部播放栏已改为全局悬浮球。正在播放本书时不再占底部空间，
    // 只保留「继续/开始播放」按钮（已在播时点击无操作，避免打断）。
    if (isCurrent) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: () => context.pushPlayerPage(),
            icon: const Icon(Icons.equalizer_rounded),
            label: const Text('正在播放 · 打开播放页'),
          ),
        ),
      );
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
        context.pushThrottled(AppPageRoute(
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

/// 目录聚合浮动小圆钮（独立 State，拖动只重绘自身，不重建整页列表）：
/// - 单击展开竖排菜单：回顶部 / 定位正在播放 / 正倒序切换
/// - 长按整钮可拖动换位置（松手持久化），菜单展开时拖动无效
/// - 默认悬浮于右下角
class _ChapterFab extends StatefulWidget {
  final ScrollController scrollController;
  final bool descending;
  final VoidCallback onLocate;
  final VoidCallback onToggleOrder;

  const _ChapterFab({
    required this.scrollController,
    required this.descending,
    required this.onLocate,
    required this.onToggleOrder,
  });

  @override
  State<_ChapterFab> createState() => _ChapterFabState();
}

class _ChapterFabState extends State<_ChapterFab> {
  static const double fabSize = 44;

  /// null = 默认右下角
  Offset? _offset;
  bool _menuOpen = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _offset = context.read<StorageService>().getChapterToolbarOffset();
    _initialized = true;
  }

  Offset _defaultOffset(Size size) =>
      Offset(size.width - fabSize - 16, size.height - 260);

  void _onPan(DragUpdateDetails d) {
    // 菜单展开时不允许拖（避免菜单和按钮错位）
    if (_menuOpen) return;
    setState(() {
      final size = MediaQuery.of(context).size;
      var dx = (_offset ?? _defaultOffset(size)).dx + d.delta.dx;
      var dy = (_offset ?? _defaultOffset(size)).dy + d.delta.dy;
      dx = dx.clamp(0.0, size.width - fabSize);
      dy = dy.clamp(0.0, size.height - fabSize - 80);
      _offset = Offset(dx, dy);
    });
  }

  Future<void> _persist() async {
    if (_offset == null) return;
    await context
        .read<StorageService>()
        .saveChapterToolbarOffset(_offset!);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pos = _offset ?? _defaultOffset(size);
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        // 竖排图标菜单：紧贴小圆钮上方；靠顶放不下时改放下方（绝不与圆钮重叠）
        if (_menuOpen)
          Builder(builder: (context) {
            const menuHeight = 3 * 48 + 2 * 4;
            var menuTop = pos.dy - menuHeight - 8;
            if (menuTop < 8) menuTop = pos.dy + 44 + 8;
            return Positioned(
              left: pos.dx.clamp(0.0, size.width - 48),
              top: menuTop,
              child: _buildMenu(context, scheme),
            );
          }),
        // 小圆钮本体
        Positioned(
          left: pos.dx,
          top: pos.dy,
          child: GestureDetector(
            onPanUpdate: _onPan,
            onPanEnd: (_) => _persist(),
            onTap: () => setState(() => _menuOpen = !_menuOpen),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primaryContainer,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                _menuOpen ? Icons.close_rounded : Icons.my_location_rounded,
                color: scheme.onPrimaryContainer,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenu(BuildContext context, ColorScheme scheme) {
    Widget item(IconData icon, String tooltip, VoidCallback onTap) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            setState(() => _menuOpen = false);
            onTap();
          },
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 22, color: scheme.primary),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        item(
          Icons.vertical_align_top_rounded,
          '回到顶部',
          () => widget.scrollController.hasClients
              ? widget.scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                )
              : null,
        ),
        const SizedBox(height: 4),
        item(Icons.my_location_rounded, '定位播放', widget.onLocate),
        const SizedBox(height: 4),
        item(
          widget.descending ? Icons.south_rounded : Icons.north_rounded,
          widget.descending ? '改为正序' : '改为倒序',
          widget.onToggleOrder,
        ),
      ],
    );
  }
}

/// 首字渐变占位封面（无封面时的默认显示）。
// 旧的自绘占位封面已删除：与书架页那份是同一种「随机渐变 + 单个汉字 +
// title.hashCode 取色」实现，两处各写一遍且色板还不一样。
// 现统一由 widgets/book_cover.dart 的 BookCover 负责（设计规范 §4）。
