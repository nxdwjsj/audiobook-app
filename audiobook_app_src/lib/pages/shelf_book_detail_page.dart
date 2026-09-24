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
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
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

  /// 简介默认收起（4 行），点「展开」看全文。长简介在详情页占掉首屏，
  /// 而首屏最该出现的是封面与目录。
  bool _descriptionExpanded = false;

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
    final int index;
    if (player.hasBook && player.currentBook!.id == widget.book.id) {
      index = player.currentChapterIndex;
    } else {
      // 这本书没在播：定位到上次听到的位置 —— 按「定位」的人想找回自己的进度，
      // 而不是被无声忽略（旧实现在非在播状态下直接 return，按钮像坏了）。
      index = context
              .read<ProgressRepository>()
              .getProgress(widget.book.id)
              ?.chapterIndex ??
          0;
    }
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
      backgroundColor: AppTheme.pageTopColor(Theme.of(context).brightness),
      appBar: AppBar(
        // 顶栏**不带标题**：头部 Hero 已经用 display 字号放了书名，
        // 再在顶栏放一次是重复噪声（也占一整行）。这里只留返回与动作。
        toolbarHeight: 48,
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
      body: _buildBody(context, isCurrent, player, progress),
      bottomNavigationBar: _buildBottomBar(context, isCurrent, player, progress),
    );
  }

  Widget _buildBody(BuildContext context, bool isCurrent,
      AudioPlayerService player, PlaybackProgress? progress) {
    final chapters = _displayChapters;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // header + 简介 + 目录工具行 + 分页条
    const headerCount = 4;
    return ListView.builder(
      controller: _scrollController,
      // 底部留出底部动作条的空间，避免最后一行被遮挡
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: headerCount + chapters.length,
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader(context, progress, isDark);
        if (index == 1) return _buildDescription(context, isDark);
        if (index == 2) return _buildSectionRow(context, isDark);
        if (index == 3) return _buildPageSelector(context, isDark);
        final rowIndex = index - headerCount;
        // 当前页数据已应用排序，映射回真实章节下标
        final pageStart = _page * _pageSize;
        final chapterIndex = _descending
            ? _chapters.length - 1 - (pageStart + rowIndex)
            : pageStart + rowIndex;
        return _buildChapterRow(
          context: context,
          chapterIndex: chapterIndex,
          chapter: chapters[rowIndex],
          isPlaying: isCurrent && chapterIndex == player.currentChapterIndex,
          isDark: isDark,
        );
      },
      // 添加缓存扩展以提高滚动性能
      scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
    );
  }

  /// 目录区的一行：左「目录 N 集」，右三个工具（排序 / 定位 / 回顶）。
  ///
  /// 此前这三个动作收在一个**可拖动的浮动圆钮**里（点开才展开菜单），
  /// 与全局悬浮球是同一种反模式：要记住它藏在哪、还要多点一次。
  /// 常驻播放条已经占住底部，目录工具就固定放在目录标题这一行 ——
  /// 它属于目录，而不是浮在整页之上。
  Widget _buildSectionRow(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, 4, 0),
      child: Row(
        children: [
          Text(
            '目录',
            style: AppType.body.copyWith(
              fontWeight: FontWeight.w500,
              color: AppInk.primary(isDark),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '${_chapters.length} 集',
            style: AppType.caption.copyWith(color: AppInk.tertiary(isDark)),
          ),
          const Spacer(),
          _toolButton(
            context,
            isDark: isDark,
            icon: _descending ? Icons.south_rounded : Icons.north_rounded,
            tooltip: _descending ? '改为正序' : '改为倒序',
            onPressed: () {
              setState(() => _descending = !_descending);
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(0);
              }
            },
          ),
          _toolButton(
            context,
            isDark: isDark,
            icon: Icons.my_location_rounded,
            tooltip: '定位到当前集',
            onPressed: () => _scrollToPlaying(force: true),
          ),
          _toolButton(
            context,
            isDark: isDark,
            icon: Icons.vertical_align_top_rounded,
            tooltip: '回到顶部',
            onPressed: () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  0,
                  duration: AppMotion.list,
                  curve: AppMotion.standard,
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _toolButton(
    BuildContext context, {
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      color: AppInk.secondary(isDark),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  /// 章节行：集号右对齐成一列 + 标题 + 正在播放标记。
  ///
  /// 正在播放的行用**左侧 2px 强调色竖条**表达 —— 与常驻迷你播放条顶边的
  /// 进度线是同一种语言，不用给整行铺底色（铺底色在长目录里会闪成一片）。
  Widget _buildChapterRow({
    required BuildContext context,
    required int chapterIndex,
    required Chapter chapter,
    required bool isPlaying,
    required bool isDark,
  }) {
    final accent = AppInk.accent(isDark);
    return InkWell(
      key: _chapterRowKeys[chapterIndex] ??= GlobalKey(),
      onTap: () => _playChapter(context, chapterIndex),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isPlaying ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '${chapterIndex + 1}',
                textAlign: TextAlign.right,
                style: AppType.micro.copyWith(
                  color: isPlaying ? accent : AppInk.tertiary(isDark),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.body.copyWith(
                  fontWeight: isPlaying ? FontWeight.w500 : FontWeight.w400,
                  color: isPlaying
                      ? AppInk.primary(isDark)
                      : AppInk.secondary(isDark),
                ),
              ),
            ),
            if (isPlaying) ...[
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.graphic_eq_rounded, size: 16, color: accent),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '正在播放',
                style: AppType.micro.copyWith(color: accent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 分页条：1-300 / 301-600 / …，点击切换当前显示的章节区间。
  ///
  /// 规范 §3：芯片/卡片**不用描边**，选中态改用墨色实底（与未选中的次级灰
  /// 形成对比），描边在纸白底上只会显脏。
  Widget _buildPageSelector(BuildContext context, bool isDark) {
    if (_pageCount <= 1) return const SizedBox.shrink();
    // 每个 chip 都要判断「是不是在播放页」，这里整体算一次就够
    final playingPage = _playingPageIndex;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: _pageCount,
        itemBuilder: (ctx, i) {
          final s = i * _pageSize + 1;
          final e = ((i + 1) * _pageSize).clamp(0, _chapters.length);
          final selected = i == _page;
          final isPlayingPage = i == playingPage;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () => setState(() {
                _page = i;
                _scrolledToPlaying = true; // 手动切页后不再自动定位
              }),
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppInk.solid(isDark) : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  '$s-$e${isPlayingPage && !selected ? ' ⏵' : ''}',
                  style: AppType.micro.copyWith(
                    color: selected
                        ? AppInk.onSolid(isDark)
                        : AppInk.secondary(isDark),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 详情页头部（设计规范 §5.8：与「在听」主打卡同一套语言）。
  ///
  /// 封面放大到 132×176 并**可点直接续播** —— 进详情页最常见的目的就是
  /// 「接着听这本」，不该还要先找到底部按钮。
  /// 收听进度是「还要听多久」的依据，用强调色（规范 §1.2：进度 = 强调色）。
  Widget _buildHeader(
      BuildContext context, PlaybackProgress? progress, bool isDark) {
    final total = _book.chapterCount;
    final heard = progress?.chapterIndex ?? -1;
    final percent =
        (progress != null && total > 0) ? ((heard + 1) / total * 100).round() : 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _resumePlay(
                context, progress?.chapterIndex ?? 0, progress?.positionSeconds ?? 0),
            child: _buildCover(),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _book.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.display.copyWith(
                    color: AppInk.primary(isDark),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _book.author == null || _book.author!.isEmpty
                      ? '未知演播'
                      : '${_book.author} 演播',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 演播署名用正文级：它是「谁演播的」，是用户选书的关键信息，
                  // 不该退化成灰色小字。
                  style: AppType.body.copyWith(
                    color: AppInk.secondary(isDark),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '$total 集 · ${_sourceLabel()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(
                    color: AppInk.tertiary(isDark),
                  ),
                ),
                if (progress != null && percent > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '已听到第 ${heard + 1} 集 · $percent%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.micro.copyWith(
                      color: AppInk.accent(isDark),
                    ),
                  ),
                ],
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
  Widget _buildCover() {
    return SizedBox(
      // 规范 §4：封面统一 3:4 竖版；详情页与「在听」主打卡同档尺寸（132×176）
      width: 132,
      height: 176,
      child: BookCover(
        title: _book.title,
        author: _book.author,
        customImagePath: _book.localCoverPath,
        networkCoverUrl: _book.coverUrl,
        memCacheWidth: 600,
      ),
    );
  }

  /// 简介：默认 4 行，点「展开」看全文。
  ///
  /// 收听进度已从这里的 Chip 移到头部（与书名同一屏），Chip 的描边与图标
  /// 在纸白底上是最显脏的一块，也不承载新信息。
  Widget _buildDescription(BuildContext context, bool isDark) {
    final desc = _book.description;
    if (desc == null || desc.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            desc,
            style: AppType.body.copyWith(color: AppInk.secondary(isDark)),
            maxLines: _descriptionExpanded ? null : 4,
            overflow:
                _descriptionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.xs),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () =>
                setState(() => _descriptionExpanded = !_descriptionExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
              child: Text(
                _descriptionExpanded ? '收起' : '展开',
                style: AppType.micro.copyWith(color: AppInk.accent(isDark)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, bool isCurrent,
      AudioPlayerService player, PlaybackProgress? progress) {
    // 常驻播放条只在首页层级显示，详情页是推送路由、不会看到它，
    // 所以这里保留自己的底部动作条：已在播本书时给「打开播放页」，
    // 未播时给「继续/开始播放」。
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
