import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import '../services/cloud_drive_service.dart';
import '../services/quark_drive_service.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_browser_page.dart';
import 'shelf_book_detail_page.dart';

/// 搜索页：搜索夸克网盘文件 + 本地书架。
/// 网盘结果点文件夹进入浏览（长按可加入书架），音频直接加入书架。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  String? _error;
  List<DriveItem> _driveResults = [];
  List<BookshelfBook> _shelfResults = [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _search);
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _driveResults = [];
        _shelfResults = [];
        _error = null;
      });
      return;
    }

    // 本地书架过滤（即时）
    final shelf = context
        .read<BookshelfRepository>()
        .getAll()
        .where((b) =>
            b.title.toLowerCase().contains(q.toLowerCase()) ||
            (b.author?.toLowerCase().contains(q.toLowerCase()) ?? false))
        .toList();

    setState(() {
      _query = q;
      _shelfResults = shelf;
      _loading = true;
      _error = null;
    });

    // 夸克网盘搜索
    try {
      final drive = context.read<QuarkDriveService>();
      if (drive.authStatus != AuthStatus.authenticated) {
        setState(() {
          _driveResults = [];
          _loading = false;
        });
        return;
      }
      final results = await drive.searchFiles(q);
      if (mounted && _controller.text.trim() == q) {
        setState(() {
          _driveResults = results;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && _controller.text.trim() == q) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索书架或网盘文件...',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _search(),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () {
                _controller.clear();
                _search();
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_rounded,
                size: 72,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text('搜索书架中的书，或夸克网盘里的文件',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return ListView(
      children: [
        if (_shelfResults.isNotEmpty) ...[
          _sectionHeader(Icons.library_books_rounded, '书架'),
          ..._shelfResults.map((b) => ListTile(
                leading: const Icon(Icons.menu_book_rounded),
                title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${b.chapterCount} 集'),
                onTap: () => context.pushThrottled(MaterialPageRoute(
                  builder: (_) => ShelfBookDetailPage(book: b),
                )),
              )),
        ],
        _sectionHeader(Icons.cloud_rounded, '夸克网盘'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('网盘搜索失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          )
        else if (_driveResults.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('网盘中未找到相关文件')),
          )
        else
          ..._driveResults.map((item) => ListTile(
                leading: Icon(
                  item.isDir
                      ? Icons.folder_rounded
                      : Icons.audio_file_rounded,
                  color: item.isDir ? Colors.amber.shade700 : null,
                ),
                title: Text(item.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(item.path),
                onTap: () => _openDriveItem(item),
              )),
      ],
    );
  }

  Widget _sectionHeader(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

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
      // 音频文件：跳到所在文件夹浏览页（可加入书架）
      context.pushThrottled(MaterialPageRoute(
        builder: (_) => DriveBrowserPage(
          initialDrive: DriveType.quark,
          initialPath: item.parentPath,
        ),
      ));
    }
  }
}
