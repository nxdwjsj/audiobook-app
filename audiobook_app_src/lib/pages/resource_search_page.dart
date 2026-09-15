import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/drive_item.dart';
import '../repositories/book_source_repository.dart';
import '../repositories/bookshelf_repository.dart';
import '../services/audio_player_service.dart';
import '../services/book_source/online_book_hit.dart';
import '../services/cloud_drive_service.dart';
import '../services/quark_drive_service.dart';
import '../services/resource_search_service.dart';
import '../services/storage_service.dart';
import '../widgets/frosted_glass.dart';
import '../widgets/throttled_navigator.dart';
import 'book_source_page.dart';
import 'drive_browser_page.dart';
import 'shelf_book_detail_page.dart';

/// 搜索范围。搜索前可勾选，三路来源的结果分开展示、不会混在一起。
enum _Scope { local, drive, online }

/// 统一搜索页：一个入口搜「本地书架 / 我的网盘 / 网盘分享 / 在线听书」。
///
/// - 本地：书架里的书（内存过滤）
/// - 网盘：我的网盘文件 + 书源发现的网盘分享链接
/// - 在线：在线听书站（点开即听，无需转存）
class ResourceSearchPage extends StatefulWidget {
  const ResourceSearchPage({super.key});

  @override
  State<ResourceSearchPage> createState() => _ResourceSearchPageState();
}

class _ResourceSearchPageState extends State<ResourceSearchPage> {
  final TextEditingController _keyword = TextEditingController();

  /// 已勾选的搜索范围，默认三路全开。
  final Set<_Scope> _scopes = {
    _Scope.local,
    _Scope.drive,
    _Scope.online,
  };

  // --- 结果：按来源分区存放，互不混排 ---
  final List<BookshelfBook> _shelfResults = []; // 本地书架
  final List<DriveItem> _driveResults = []; // 我的网盘文件
  final List<ResourceResult> _shareResults = []; // 网盘分享链接
  final List<OnlineBookHit> _onlineHits = []; // 在线听书站

  bool _driveLoading = false;
  String? _driveError;

  String? _progress;
  bool _searching = false;

  /// 正在转存/加入书架的那本书（key）。用整页级布尔量会让所有卡片一起转圈。
  String? _shelvingKey;

  /// 转存目标目录。null = 用夸克的「来自：分享」目录
  String? _saveDirFid;

  /// 目标目录显示名（如「来自：分享」「小说」）
  String _saveDirName = '来自：分享';

  /// 目标目录的绝对路径（'' = 根目录）。用于拼书的存放路径。
  String _absoluteSavePath = '';

  @override
  void initState() {
    super.initState();
    final storage = context.read<StorageService>();
    _saveDirFid = storage.getQuarkSaveDirFid();
    _saveDirName = storage.getQuarkSaveDirName() ?? '来自：分享';
    final storedPath = storage.getQuarkSaveDirPath();
    _absoluteSavePath = (storedPath == null || storedPath == '根目录')
        ? ''
        : (storedPath.startsWith('/') ? storedPath : '/$storedPath');
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  /// 选择转存到网盘的哪个目录（记住选择，下次直接用）。
  Future<void> _pickSaveDir() async {
    final quark = context.read<QuarkDriveService>();
    final picked = await showFrostedBottomSheet<(String, String)>(
      context: context,
      builder: (_) => _SaveDirPicker(quark: quark),
    );
    if (picked == null || !mounted) return;
    final storage = context.read<StorageService>();
    // picked: (fid, 绝对路径)。'' = 默认「来自：分享」，'/' = 根目录。
    final isDefaultInbox = picked.$1.isEmpty && picked.$2.isEmpty;
    final absPath = isDefaultInbox
        ? ''
        : (picked.$2 == '/' ? '' : '/${picked.$2.replaceAll(RegExp(r'^/+|/+$'), '')}');
    final displayName = isDefaultInbox
        ? '来自：分享'
        : (absPath.isEmpty ? '根目录' : absPath.split('/').last);
    await storage.saveQuarkSaveDir(picked.$1, displayName, absPath);
    if (!mounted) return;
    setState(() {
      _saveDirFid = picked.$1.isEmpty ? null : picked.$1;
      _saveDirName = displayName;
      _absoluteSavePath = absPath;
    });
  }

  Future<void> _search() async {
    // 输入框回车和搜索按钮都可能触发，搜索中直接忽略，避免两次结果交错
    if (_searching) return;
    final kw = _keyword.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入书名或关键词')),
      );
      return;
    }
    if (_scopes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少勾选一个搜索范围')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _shelfResults.clear();
      _driveResults.clear();
      _shareResults.clear();
      _onlineHits.clear();
      _driveError = null;
      _progress = '准备…';
    });

    // 本地书架：内存过滤，无需等待
    if (_scopes.contains(_Scope.local)) {
      final q = kw.toLowerCase();
      final shelf = context
          .read<BookshelfRepository>()
          .getAll()
          .where((b) =>
              b.title.toLowerCase().contains(q) ||
              (b.author?.toLowerCase().contains(q) ?? false))
          .toList();
      if (mounted) setState(() => _shelfResults.addAll(shelf));
    }

    // 三路网络搜索并行，各自写入自己的分区
    final tasks = <Future<void>>[];
    if (_scopes.contains(_Scope.drive)) {
      tasks.add(_searchDriveFiles(kw));
      tasks.add(_searchShares(kw));
    }
    if (_scopes.contains(_Scope.online)) {
      tasks.add(_searchOnline(kw));
    }
    await Future.wait(tasks);

    if (mounted) {
      setState(() {
        _searching = false;
        _progress = null;
      });
    }
  }

  /// 我的网盘文件（夸克网盘 API 搜索）。
  Future<void> _searchDriveFiles(String kw) async {
    final drive = context.read<QuarkDriveService>();
    if (drive.authStatus != AuthStatus.authenticated) {
      if (mounted) setState(() => _driveError = '夸克网盘未登录');
      return;
    }
    if (mounted) setState(() => _driveLoading = true);
    try {
      final results = await drive.searchFiles(kw);
      if (mounted) setState(() => _driveResults.addAll(results));
    } catch (e) {
      if (mounted) setState(() => _driveError = '$e');
    } finally {
      if (mounted) setState(() => _driveLoading = false);
    }
  }

  /// 网盘分享链接（书源发现，可转存后播放）。
  Future<void> _searchShares(String kw) async {
    final service = context.read<ResourceSearchService>();
    try {
      final list = await service.search(
        kw,
        maxParse: 8,
        onProgress: (m) {
          if (mounted) setState(() => _progress = m);
        },
        // 边解析边出结果，首条结果几秒内就能看到。
        onResult: (r) {
          if (!mounted) return;
          setState(() {
            _shareResults.add(r);
            _shareResults.sort(_compare);
          });
        },
      );
      if (mounted) {
        setState(() {
          _shareResults
            ..clear()
            ..addAll(list);
        });
      }
    } catch (e) {
      debugPrint('[Search] 网盘分享: $e');
    }
  }

  /// 在线听书站（无需转存，点开即听）。
  Future<void> _searchOnline(String kw) async {
    final service = context.read<ResourceSearchService>();
    try {
      final hits = await service.searchOnline(kw);
      if (mounted) setState(() => _onlineHits.addAll(hits));
    } catch (e) {
      debugPrint('[Search] 在线听书: $e');
    }
  }

  static int _compare(ResourceResult a, ResourceResult b) {
    if ((a.error == null) != (b.error == null)) {
      return a.error == null ? -1 : 1;
    }
    final c = b.keywordHits.compareTo(a.keywordHits);
    if (c != 0) return c;
    return b.audioItems.length.compareTo(a.audioItems.length);
  }

  /// 书在书架里的 id。同一个分享可能拆出多本书，因此不能只用分享链接。
  String _bookIdFor(ResourceResult r) =>
      DriveItem.bookIdFor(DriveType.quark, '${r.shareUrl}|${r.title}');

  /// 加入书架（可选立即播放）。返回是否成功。
  ///
  /// 夸克分享文件没有直链，必须先转存到自己的网盘，转存后的 fid 才能播放。
  Future<bool> _shelve(ResourceResult r, {bool play = false}) async {
    // 转存 + 入架期间锁住，连点会并发 playBook 并把播放页压两层
    if (_shelvingKey != null) return false;
    final messenger = ScaffoldMessenger.of(context);
    final audio = r.audioItems;
    if (audio.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('该分享里没有音频文件')));
      return false;
    }
    setState(() => _shelvingKey = _bookIdFor(r));
    try {
      final repo = context.read<BookshelfRepository>();
      final player = context.read<AudioPlayerService>();
      final quark = context.read<QuarkDriveService>();

      setState(() => _progress = '正在转存「${r.title}」到「$_saveDirName」…');
      SaveShareResult savedResult;
      try {
        // 只转存这一本书（entries = 该书的顶层条目），而不是整个合集
        savedResult = await quark.saveShareToMyDrive(
          r.shareUrl,
          pwd: r.passcode,
          entries: r.shareEntries,
          toDirFid: _saveDirFid,
        );
      } catch (e) {
        if (mounted) setState(() => _progress = null);
        messenger.showSnackBar(SnackBar(content: Text('转存失败：$e')));
        return false;
      }
      if (mounted) setState(() => _progress = null);
      final saved = savedResult.audioFiles;
      if (saved.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('该分享里没有可播放的音频文件')));
        return false;
      }

      // 章节 fid 已是自己网盘的 fid，因此不再标记为分享文件（走普通下载直链）。
      final book = DriveItem.folderToBook(
        folderName: r.title,
        audioFiles: saved,
        driveType: DriveType.quark,
        bookId: _bookIdFor(r),
      );
      // 记录这本书在网盘里的存放位置，书架长按即可跳进去。
      // 顶层是目录 → 用转存后的目录 fid；顶层是散文件 → 只能到所在目录。
      // 默认「来自：分享」没有 fid（由夸克自动定位），按名字也能被网盘页解析。
      final rawParent = _absoluteSavePath;
      final parentPath = rawParent == '/' ? '' : rawParent;
      final fallbackParent = parentPath.isNotEmpty
          ? parentPath
          : (_saveDirFid == null ? '/来自：分享' : '/');
      final bookDirFid = savedResult.savedDirFid ?? _saveDirFid;
      final String? bookDirPath;
      if (savedResult.savedDirName != null) {
        bookDirPath =
            parentPath.isEmpty ? '/${savedResult.savedDirName}' : '$parentPath/${savedResult.savedDirName}';
      } else {
        bookDirPath = fallbackParent;
      }
      await repo.add(BookshelfBook(
        id: book.id,
        title: book.title,
        author: book.author,
        chapterCount: book.chapters.length,
        driveType: DriveType.quark,
        isFromShare: false,
        shareUrl: r.shareUrl,
        driveDirFid: bookDirFid,
        drivePath: bookDirPath,
        chapters: book.chapters,
      ));
      if (play) {
        await player.playBook(book);
        if (mounted) context.pushPlayerPage();
      }
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(play
              ? '已开始播放「${book.title}」'
              : '「${book.title}」已转存并加入书架（${book.chapters.length} 集）'),
        ));
      }
      return true;
    } finally {
      if (mounted) setState(() => _shelvingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: [
          // 书源管理入口：显示当前启用数
          IconButton(
            icon: const Icon(Icons.travel_explore_rounded),
            tooltip: '书源管理',
            onPressed: () => context.pushThrottled(
                MaterialPageRoute(builder: (_) => const BookSourcePage())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '书名 / 关键词，如 神秘复苏',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('搜索'),
                ),
              ],
            ),
          ),
          // 搜索范围：本地 / 网盘 / 在线，搜索前可自由勾选
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
            child: Wrap(
              spacing: 8,
              children: [
                _scopeChip(_Scope.local, '本地书架', Icons.library_books_rounded),
                _scopeChip(_Scope.drive, '网盘', Icons.cloud_rounded),
                _scopeChip(_Scope.online, '在线听书', Icons.headphones_rounded),
              ],
            ),
          ),
          // 转存到网盘的哪个目录（仅网盘分享用得到，点一下可更换，选择会被记住）
          if (_scopes.contains(_Scope.drive))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
              child: InkWell(
                onTap: _shelvingKey != null ? null : _pickSaveDir,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_move_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '保存到：$_saveDirName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        '更换',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _progress!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  /// 搜索范围勾选 chip（可多选）。
  Widget _scopeChip(_Scope scope, String label, IconData icon) {
    final selected = _scopes.contains(scope);
    return FilterChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: _searching
          ? null
          : (v) => setState(() {
                if (v) {
                  _scopes.add(scope);
                } else {
                  _scopes.remove(scope);
                }
              }),
    );
  }

  /// 结果区：按来源分成四个分区，先本地、再网盘（文件 + 分享）、最后在线。
  Widget _buildResults() {
    final noResult = _shelfResults.isEmpty &&
        _driveResults.isEmpty &&
        _shareResults.isEmpty &&
        _onlineHits.isEmpty;
    if (noResult && _searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (noResult) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '一个入口搜全部：本地书架 / 我的网盘 / 网盘分享 / 在线听书\n'
            '三路结果分开显示，不会混在一起',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // 1. 本地书架
        if (_scopes.contains(_Scope.local)) ...[
          _sectionHeader(
              Icons.library_books_rounded, '本地书架', _shelfResults.length),
          if (_shelfResults.isEmpty)
            _emptyHint('书架中没有匹配的书')
          else
            ..._shelfResults.map(_buildShelfTile),
        ],
        // 2. 我的网盘文件
        if (_scopes.contains(_Scope.drive)) ...[
          _sectionHeader(Icons.folder_rounded, '我的网盘', _driveResults.length),
          if (_driveLoading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_driveError != null)
            _emptyHint('网盘搜索失败：$_driveError')
          else if (_driveResults.isEmpty)
            _emptyHint('网盘中没有匹配的文件')
          else
            ..._driveResults.map(_buildDriveTile),
          // 3. 网盘分享链接
          _sectionHeader(Icons.link_rounded, '网盘分享', _shareResults.length),
          if (_searching && _shareResults.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_shareResults.isEmpty)
            _emptyHint('没有发现相关的网盘分享')
          else
            ..._shareResults.map(_buildCard),
        ],
        // 4. 在线听书站
        if (_scopes.contains(_Scope.online)) ...[
          _sectionHeader(Icons.headphones_rounded, '在线听书', _onlineHits.length),
          if (_searching && _onlineHits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_onlineHits.isEmpty)
            _emptyHint('在线书源没有搜到相关有声书')
          else
            ..._onlineHits.map(_buildOnlineCard),
        ],
      ],
    );
  }

  Widget _sectionHeader(IconData icon, String label, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  Widget _buildShelfTile(BookshelfBook b) {
    return ListTile(
      leading: const Icon(Icons.menu_book_rounded),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${b.chapterCount} 集'),
      onTap: () => context.pushThrottled(MaterialPageRoute(
        builder: (_) => ShelfBookDetailPage(book: b),
      )),
    );
  }

  Widget _buildDriveTile(DriveItem item) {
    return ListTile(
      leading: Icon(
        item.isDir ? Icons.folder_rounded : Icons.audio_file_rounded,
        color: item.isDir ? Colors.amber.shade700 : null,
      ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(item.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openDriveItem(item),
    );
  }

  /// 网盘搜索结果点开：目录进目录、音频进所在目录（可加入书架）。
  void _openDriveItem(DriveItem item) {
    if (item.isDir) {
      context.pushThrottled(MaterialPageRoute(
        builder: (_) => DriveBrowserPage(
          initialDrive: DriveType.quark,
          initialPath: item.path,
          initialDirFid: item.fileId,
        ),
      ));
    } else {
      context.pushThrottled(MaterialPageRoute(
        builder: (_) => DriveBrowserPage(
          initialDrive: DriveType.quark,
          initialPath: item.parentPath,
        ),
      ));
    }
  }

  /// 在线书源命中的书 id：online_{书源id}_{详情页路径}
  String _onlineBookIdFor(OnlineBookHit h) {
    final uri = Uri.tryParse(h.detailUrl);
    final path = (uri?.path ?? h.detailUrl)
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return 'online_${h.source}_$path';
  }

  /// 在线书加入书架（可选立即播放）：
  /// 解析详情页章节列表（播放页地址）存进书架，音频直链播放时再懒解析。
  Future<bool> _shelveOnline(OnlineBookHit h, {bool play = false}) async {
    if (_shelvingKey != null) return false;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _shelvingKey = _onlineBookIdFor(h));
    try {
      final service = context.read<ResourceSearchService>();
      final repo = context.read<BookshelfRepository>();
      final player = context.read<AudioPlayerService>();
      setState(() => _progress = '正在解析「${h.title}」的章节列表…');
      OnlineBookDetail detail;
      try {
        detail = await service.resolveOnlineChapters(h);
      } catch (e) {
        if (mounted) setState(() => _progress = null);
        messenger.showSnackBar(SnackBar(content: Text('解析章节失败：$e')));
        return false;
      }
      if (mounted) setState(() => _progress = null);
      if (detail.chapters.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('该书没有解析到章节')));
        return false;
      }

      final bookId = _onlineBookIdFor(h);
      final chapters = [
        for (final (i, c) in detail.chapters.indexed)
          Chapter(
            filename: c.url,
            title: _cleanOnlineTitle(h.title, c.title, i),
            duration: Duration.zero,
            // shareUrl 存书源 id：播放器懒解析时据此找规则
            shareUrl: h.source,
          ),
      ];
      await repo.add(BookshelfBook(
        id: bookId,
        title: h.title,
        author: detail.author ?? h.author,
        chapterCount: chapters.length,
        isLocal: false,
        shareUrl: h.detailUrl,
        chapters: chapters,
      ));
      if (play) {
        await player.playBook(Book(
          id: bookId,
          title: h.title,
          author: detail.author ?? h.author,
          chapters: chapters,
        ));
        if (mounted) context.pushPlayerPage();
      }
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(play
              ? '已开始播放「${h.title}」'
              : '「${h.title}」已加入书架（${chapters.length} 集）'),
        ));
      }
      return true;
    } finally {
      if (mounted) setState(() => _shelvingKey = null);
    }
  }

  /// 章节标题去重书名前缀：详情页 title 常是「书名 章节名」。
  String _cleanOnlineTitle(String bookTitle, String rawTitle, int index) {
    var t = rawTitle;
    if (t.startsWith('$bookTitle ')) {
      t = t.substring(bookTitle.length + 1);
    } else if (t.startsWith(bookTitle)) {
      t = t.substring(bookTitle.length);
    }
    t = t.trim();
    return t.isEmpty ? '第 ${index + 1} 集' : t;
  }

  Widget _buildOnlineCard(OnlineBookHit h) {
    final theme = Theme.of(context);
    final inShelf =
        context.read<BookshelfRepository>().isInShelf(_onlineBookIdFor(h));
    final sourceName = context
            .read<BookSourceRepository>()
            .all
            .where((s) => s.id == h.source)
            .firstOrNull
            ?.name ??
        h.source;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: Icon(Icons.headphones_rounded,
            color: theme.colorScheme.primary),
        title: Text(
          h.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$sourceName · 在线收听${h.author != null && h.author!.isNotEmpty ? ' · ${h.author}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_shelvingKey == _onlineBookIdFor(h))
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else ...[
              if (!inShelf)
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: '加入书架',
                  onPressed:
                      _shelvingKey != null ? null : () => _shelveOnline(h),
                ),
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded),
                tooltip: '播放',
                onPressed: _shelvingKey != null
                    ? null
                    : () => _shelveOnline(h, play: true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCard(ResourceResult r) {
    final theme = Theme.of(context);
    final inShelf =
        context.read<BookshelfRepository>().isInShelf(_bookIdFor(r));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        title: Text(
          r.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: r.error != null
            ? Text(r.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.error))
            : Text(
                '${_sourceLabel(r.source)} · ${r.audioItems.length} 集 · '
                '${_fmtSize(r.audioBytes)}'
                '${r.keywordHits > 0 ? ' · 命中关键词' : ''}',
              ),
        trailing: r.error != null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_shelvingKey == _bookIdFor(r))
                    // 正在转存这一本：给个明确的忙碌反馈，顺便锁住按钮
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  else ...[
                    if (!inShelf)
                      IconButton(
                        icon: const Icon(Icons.add_rounded),
                        tooltip: '加入书架',
                        onPressed:
                            _shelvingKey != null ? null : () => _shelve(r),
                      ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded),
                      tooltip: '播放',
                      onPressed:
                          _shelvingKey != null ? null : () => _shelve(r, play: true),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  String _sourceLabel(String source) {
    // 书源名优先（含自定义源），找不到再回退到内置渠道的旧映射
    final s = context
        .read<BookSourceRepository>()
        .all
        .where((s) => s.id == source)
        .firstOrNull;
    if (s != null) return s.name;
    switch (source) {
      case 'bilibili':
        return 'B站';
      case 'yigushi':
        return '第一故事';
      case 'yangzhiyi':
        return 'Mp3故事网';
      case 'slowread':
        return 'slowread';
      case 'fangkong':
        return '放空一夏';
      default:
        return source;
    }
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// 转存目标目录选择器：浏览自己网盘的目录树，选定后返回 (fid, 名称)。
/// fid 为空字符串表示沿用夸克默认的「来自：分享」目录。
class _SaveDirPicker extends StatefulWidget {
  const _SaveDirPicker({required this.quark});

  final QuarkDriveService quark;

  @override
  State<_SaveDirPicker> createState() => _SaveDirPickerState();
}

class _SaveDirPickerState extends State<_SaveDirPicker> {
  /// 当前路径（fid, 名称），空表示根目录
  final List<(String, String)> _stack = [];
  List<DriveItem> _dirs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _pathLabel =>
      _stack.isEmpty ? '根目录' : _stack.map((e) => e.$2).join(' / ');

  /// 当前目录在网盘里的绝对路径（如 /有声书/小说），根目录为 ''。
  String get _absolutePath => _stack.map((e) => e.$2).join('/');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.quark
          .listFolder(dirFileId: _stack.isEmpty ? null : _stack.last.$1);
      if (!mounted) return;
      setState(() {
        _dirs = items.where((i) => i.isDir).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _enter(DriveItem dir) {
    _stack.add((dir.fileId, dir.name));
    _load();
  }

  void _up() {
    if (_stack.isEmpty) return;
    _stack.removeLast();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fid = _stack.isEmpty ? '0' : _stack.last.$1;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child:
                        Text('选择保存位置', style: theme.textTheme.titleMedium),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (_stack.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                      tooltip: '上一级',
                      onPressed: _up,
                    ),
                  Expanded(
                    child: Text(
                      _pathLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 8),
            Expanded(child: _buildList(theme)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.inbox_rounded, size: 18),
                      label: const Text('用「来自：分享」（默认）'),
                      onPressed: () =>
                          Navigator.pop(context, ('', '')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: Text('保存到「$_pathLabel」'),
                      onPressed: () =>
                          Navigator.pop(context, (fid, _absolutePath)),
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

  Widget _buildList(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '读取目录失败：$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (_dirs.isEmpty) {
      return const Center(child: Text('这个文件夹里没有子文件夹'));
    }
    return ListView.builder(
      itemCount: _dirs.length,
      itemBuilder: (context, i) {
        final d = _dirs[i];
        return ListTile(
          leading: const Icon(Icons.folder_rounded),
          title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _enter(d),
        );
      },
    );
  }
}
