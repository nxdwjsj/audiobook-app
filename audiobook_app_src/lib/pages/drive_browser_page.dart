import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../models/drive_item.dart';
import '../models/book.dart';
import '../services/baidu_drive_service.dart';
import '../services/quark_drive_service.dart';
import '../services/audio_player_service.dart';
import '../services/cloud_drive_service.dart';
import '../repositories/bookshelf_repository.dart';
import '../models/bookshelf_book.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_login_page.dart';

/// Cloud drive file browser page.
/// Supports browsing own drive files (Scheme A) and parsing share links (Scheme B).
class DriveBrowserPage extends StatefulWidget {
  /// 初始目录（书架“进入详情”跳转用）：目标网盘类型 + 文件夹路径 + fid。
  final DriveType? initialDrive;
  final String? initialPath;
  final String? initialDirFid;

  const DriveBrowserPage({
    super.key,
    this.initialDrive,
    this.initialPath,
    this.initialDirFid,
  });

  @override
  State<DriveBrowserPage> createState() => _DriveBrowserPageState();
}

/// A breadcrumb entry (name + the path it points to).
class _Crumb {
  final String name;
  final String path;
  const _Crumb(this.name, this.path);
}

class _DriveBrowserPageState extends State<DriveBrowserPage> {
  late DriveType _selectedDrive =
      widget.initialDrive ?? DriveType.baidu;
  late String _currentPath = widget.initialPath ?? '/';
  late final List<_Crumb> _crumbs = [
    const _Crumb('根目录', '/'),
    if (widget.initialPath != null)
      ..._crumbsFor(widget.initialPath!),
  ];

  /// Quark needs the fid for fast navigation; remember it per crumb path.
  final Map<String, String> _pathFid = {};

  List<DriveItem> _items = [];
  bool _loading = false;
  String? _error;
  bool _shareCardExpanded = false;
  String _filter = '';
  bool _showFoldersOnly = false;

  /// 目录加载请求序号（竞态守卫：旧响应到达时被丢弃）。
  int _loadSeq = 0;

  /// 非空 = 当前展示的是分享解析结果（分享域文件，不能按自有盘导航进目录）。
  List<DriveItem>? _shareItems;

  final TextEditingController _shareUrlController = TextEditingController();
  final TextEditingController _sharePwdController = TextEditingController();
  final TextEditingController _filterController = TextEditingController();

  @override
  void dispose() {
    _shareUrlController.dispose();
    _sharePwdController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  CloudDriveService get _driveService {
    final service = _selectedDrive == DriveType.baidu
        ? context.read<BaiduDriveService>()
        : context.read<QuarkDriveService>();
    return service as CloudDriveService;
  }

  /// 把路径拆成面包屑（书架“进入详情”时用）。
  static List<_Crumb> _crumbsFor(String path) {
    final crumbs = <_Crumb>[];
    var acc = '';
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$seg';
      crumbs.add(_Crumb(seg, acc));
    }
    return crumbs;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialDirFid != null && widget.initialPath != null) {
      _pathFid[widget.initialPath!] = widget.initialDirFid!;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _loadFolder(dirFileId: widget.initialDirFid),
    );
  }

  Future<void> _loadFolder({String? path, String? dirFileId}) async {
    final targetPath = path ?? _currentPath;
    // 请求序号：快速连续导航时丢弃过期的旧响应（慢的旧请求后到会覆盖新目录）
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final service = _driveService;
      final items = await service.listFolder(
        path: targetPath,
        dirFileId: dirFileId,
      );
      if (mounted && seq == _loadSeq) {
        setState(() {
          _items = items;
          _currentPath = targetPath;
          _shareItems = null; // 正常目录浏览：清除分享态
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _navigateInto(DriveItem item) {
    final newPath =
        _currentPath == '/' ? '/${item.name}' : '$_currentPath/${item.name}';
    if (_selectedDrive == DriveType.quark && item.fileId.isNotEmpty) {
      _pathFid[newPath] = item.fileId;
    }
    setState(() {
      _crumbs.add(_Crumb(item.name, newPath));
      _filter = '';
      _filterController.clear();
    });
    _loadFolder(
      path: newPath,
      dirFileId: _selectedDrive == DriveType.quark ? item.fileId : null,
    );
  }

  /// Jump to a breadcrumb (e.g. tapping "根目录" or a parent folder).
  void _jumpToCrumb(int index) {
    if (index == _crumbs.length - 1) return;
    final crumb = _crumbs[index];
    setState(() {
      _crumbs.removeRange(index + 1, _crumbs.length);
      _filter = '';
      _filterController.clear();
    });
    _loadFolder(path: crumb.path, dirFileId: _pathFid[crumb.path]);
  }

  Future<void> _showFolderActions(DriveItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('打开文件夹'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_fill_rounded),
              title: const Text('播放此文件夹全部音频'),
              onTap: () => Navigator.pop(ctx, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('加入书架'),
              onTap: () => Navigator.pop(ctx, 'shelf'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'open':
        _navigateInto(item);
        break;
      case 'play':
        await _playOrShelveFolder(item);
        break;
      case 'shelf':
        await _playOrShelveFolder(item, toShelf: true);
        break;
    }
  }

  /// Load the folder's audio files and play them / add to shelf.
  ///
  /// 递归收集：文件夹内的音频 + 子文件夹中的音频（如"前50集/中50集/后50集"）。
  Future<void> _playOrShelveFolder(DriveItem folder, {bool toShelf = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = context.read<BookshelfRepository>();
    final player = context.read<AudioPlayerService>();
    setState(() => _loading = true);
    try {
      final service = _driveService;
      final folderPath = _currentPath == '/'
          ? '/${folder.name}'
          : '$_currentPath/${folder.name}';
      final audioFiles = await _collectAudioRecursively(
        service,
        folderPath,
        _selectedDrive == DriveType.quark ? folder.fileId : null,
      );
      if (audioFiles.isEmpty) {
        if (mounted) {
          setState(() => _loading = false);
          messenger.showSnackBar(
            SnackBar(content: Text('「${folder.name}」里没有音频文件')),
          );
        }
        return;
      }
      final book = DriveItem.folderToBook(
        folderName: folder.name,
        audioFiles: audioFiles,
        driveType: _selectedDrive,
        bookId: DriveItem.bookIdFor(_selectedDrive, folderPath),
      );
      if (toShelf) {
        await repository.add(BookshelfBook(
          id: book.id,
          title: book.title,
          author: book.author,
          chapterCount: book.chapters.length,
          driveType: _selectedDrive,
          drivePath: folderPath,
          driveDirFid: _selectedDrive == DriveType.quark ? folder.fileId : null,
          chapters: book.chapters,
        ));
        if (mounted) {
          setState(() => _loading = false);
          messenger.showSnackBar(
            SnackBar(content: Text('「${folder.name}」已加入书架（${book.chapters.length} 集）')),
          );
        }
      } else {
        await player.playBook(book);
        if (mounted) {
          setState(() => _loading = false);
          context.pushPlayerPage();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 深度优先递归收集文件夹（含嵌套子文件夹）中的全部音频文件。
  Future<List<DriveItem>> _collectAudioRecursively(
    CloudDriveService service,
    String path,
    String? dirFileId, {
    int depth = 0,
  }) async {
    // 防御：异常深的目录结构直接放弃
    if (depth > 5) return const [];
    final items = await service.listFolder(path: path, dirFileId: dirFileId);
    final audio = items.where((i) => i.isAudio && !i.isDir).toList();
    for (final sub in items.where((i) => i.isDir)) {
      final subPath =
          path == '/' ? '/${sub.name}' : '$path/${sub.name}';
      audio.addAll(await _collectAudioRecursively(
        service,
        subPath,
        _selectedDrive == DriveType.quark ? sub.fileId : null,
        depth: depth + 1,
      ));
    }
    return audio;
  }

  Future<void> _parseShareLink() async {
    final url = _shareUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入分享链接')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final service = _driveService;
      final result = await service.parseShareLink(
        url,
        pwd: _sharePwdController.text.trim().isEmpty
            ? null
            : _sharePwdController.text.trim(),
      );
      if (mounted) {
        setState(() {
          _items = result.items;
          _shareItems = result.items; // 标记分享态：禁用目录导航
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解析成功，共 ${result.items.length} 个文件')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// Build a Book from audio files in current folder, then play it.
  Future<void> _playFolderAsBook() async {
    final audioFiles = _visibleItems.where((i) => i.isAudio).toList();
    if (audioFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前文件夹没有音频文件')),
      );
      return;
    }

    final book = _buildBookFromFolder(audioFiles);
    final player = context.read<AudioPlayerService>();
    await player.playBook(book);
    if (mounted) {
      context.pushPlayerPage();
    }
  }

  Future<void> _playSingleFile(DriveItem item) async {
    final book = DriveItem.folderToBook(
      folderName: item.name,
      audioFiles: [item],
      driveType: _selectedDrive,
      bookId: DriveItem.bookIdFor(_selectedDrive, item.name),
    );
    final player = context.read<AudioPlayerService>();
    await player.playBook(book);
    if (mounted) {
      context.pushPlayerPage();
    }
  }

  Book _buildBookFromFolder(List<DriveItem> audioFiles) {
    final folderName =
        _currentPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '未知';
    return DriveItem.folderToBook(
      folderName: folderName,
      audioFiles: audioFiles,
      driveType: _selectedDrive,
      bookId: DriveItem.bookIdFor(_selectedDrive, _currentPath),
    );
  }

  /// Items after applying the in-folder filter.
  List<DriveItem> get _visibleItems {
    Iterable<DriveItem> list = _items;
    if (_showFoldersOnly) {
      list = list.where((i) => i.isDir);
    }
    final q = _filter.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((i) => i.name.toLowerCase().contains(q));
    }
    return list.toList();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('网盘')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '网盘功能需要在 Android/iOS 设备上使用。\n'
              'Web 平台无法调用网盘接口。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final baiduAuth = context.watch<BaiduDriveService>().authStatus;
    final quarkAuth = context.watch<QuarkDriveService>().authStatus;
    final currentAuth =
        _selectedDrive == DriveType.baidu ? baiduAuth : quarkAuth;
    final authed = currentAuth == AuthStatus.authenticated;

    return PopScope(
      // 逐级返回：非根目录时拦截返回键，先回上一级文件夹
      canPop: _currentPath == '/',
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goUpOneLevel();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('网盘'),
        actions: [
          if (authed)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _loading ? null : () => _loadFolder(),
            ),
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: '网盘设置',
            onPressed: () {
              context.pushThrottled(
                  MaterialPageRoute(builder: (_) => const DriveLoginPage()));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildDriveSelector(),
          if (authed) ...[
            _buildShareCard(),
            _buildBreadcrumb(),
            _buildToolbar(),
          ],
          const Divider(height: 1),
          Expanded(child: _buildFileList(currentAuth)),
        ],
      ),
      floatingActionButton: authed && _items.isNotEmpty
          ? FloatingActionButton(
              onPressed: _playFolderAsBook,
              tooltip: '播放此文件夹全部音频',
              child: const Icon(Icons.play_arrow_rounded),
            )
          : null,
      ),
    );
  }

  /// 返回上一级文件夹（返回键逐级回退用）。
  void _goUpOneLevel() {
    if (_crumbs.length <= 1) return;
    _jumpToCrumb(_crumbs.length - 2);
  }

  Widget _buildDriveSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SegmentedButton<DriveType>(
        segments: const [
          ButtonSegment(
            value: DriveType.baidu,
            label: Text('百度网盘'),
            icon: Icon(Icons.cloud_rounded),
          ),
          ButtonSegment(
            value: DriveType.quark,
            label: Text('夸克网盘'),
            icon: Icon(Icons.cloud_done_rounded),
          ),
        ],
        selected: {_selectedDrive},
        onSelectionChanged: (s) {
          setState(() {
            _selectedDrive = s.first;
            _currentPath = '/';
            _crumbs
              ..clear()
              ..add(const _Crumb('根目录', '/'));
            _filter = '';
            _filterController.clear();
          });
          _loadFolder();
        },
      ),
    );
  }

  Widget _buildShareCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: () =>
              setState(() => _shareCardExpanded = !_shareCardExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.link_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '解析分享链接',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    Icon(
                      _shareCardExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
                if (_shareCardExpanded) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _shareUrlController,
                          decoration: const InputDecoration(
                            hintText: '粘贴网盘分享链接',
                            isDense: true,
                            prefixIcon: Icon(Icons.link_rounded, size: 18),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 84,
                        child: TextField(
                          controller: _sharePwdController,
                          decoration: const InputDecoration(
                            hintText: '提取码',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: _loading ? null : _parseShareLink,
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('解析'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBreadcrumb() {
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _crumbs.length,
        itemBuilder: (context, index) {
          final crumb = _crumbs[index];
          final isLast = index == _crumbs.length - 1;
          return Row(
            children: [
              if (index > 0)
                Icon(Icons.chevron_right_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              TextButton(
                onPressed: isLast ? null : () => _jumpToCrumb(index),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: isLast
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.primary,
                ),
                child: Text(
                  crumb.name,
                  style: TextStyle(
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _filterController,
              onChanged: (v) => setState(() => _filter = v),
              decoration: InputDecoration(
                hintText: '在当前文件夹内筛选',
                isDense: true,
                prefixIcon: const Icon(Icons.filter_list_rounded, size: 18),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            icon: Icon(_showFoldersOnly
                ? Icons.folder_rounded
                : Icons.folder_open_rounded),
            tooltip: _showFoldersOnly ? '显示全部' : '只看文件夹',
            isSelected: _showFoldersOnly,
            onPressed: () =>
                setState(() => _showFoldersOnly = !_showFoldersOnly),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList(AuthStatus auth) {
    if (auth != AuthStatus.authenticated) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                auth == AuthStatus.expired ? '登录已过期，请重新连接' : '请先连接网盘',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  context.pushThrottled(MaterialPageRoute(
                      builder: (_) => const DriveLoginPage()));
                },
                icon: const Icon(Icons.login),
                label: const Text('连接网盘'),
              ),
            ],
          ),
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('加载失败：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => _loadFolder(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final items = _visibleItems;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadFolder(),
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Text(
                  _filter.isNotEmpty ? '没有匹配的文件' : '此文件夹为空',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadFolder(),
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final item = items[index];
          return _buildListTile(item);
        },
      ),
    );
  }

  Widget _buildListTile(DriveItem item) {
    final scheme = Theme.of(context).colorScheme;
    final isAudio = item.isAudio;
    final isDir = item.isDir;

    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isDir
              ? scheme.primaryContainer
              : (isAudio ? Colors.green.withValues(alpha: 0.15) : scheme.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          isDir
              ? Icons.folder_rounded
              : (isAudio
                  ? Icons.audio_file_rounded
                  : Icons.insert_drive_file_rounded),
          color: isDir
              ? scheme.onPrimaryContainer
              : (isAudio ? Colors.green.shade700 : scheme.onSurfaceVariant),
        ),
      ),
      title: Text(
        item.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: isDir
          ? (item.fileCount > 0 ? Text('${item.fileCount} 个文件') : null)
          : Text(_formatSize(item.size)),
      trailing: isAudio
          ? IconButton.filledTonal(
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              tooltip: '播放',
              onPressed: () => _playSingleFile(item),
            )
          : (isDir ? const Icon(Icons.chevron_right_rounded) : null),
      onLongPress: isDir ? () => _showFolderActions(item) : null,
      onTap: () {
        if (isDir) {
          // 分享解析出的目录属于分享域（fid 不在自有盘），点进去必然请求失败
          if (_shareItems != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('分享内容暂不支持进入子目录，可长按文件夹直接播放或加入书架')),
            );
            return;
          }
          _navigateInto(item);
        } else if (isAudio) {
          _playSingleFile(item);
        }
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }
}
