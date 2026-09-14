import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import '../services/audio_player_service.dart';
import '../services/resource_search_service.dart';
import '../widgets/throttled_navigator.dart';

/// 全网搜书：多渠道发现夸克网盘有声书分享，一键加入书架或直接播放。
class ResourceSearchPage extends StatefulWidget {
  const ResourceSearchPage({super.key});

  @override
  State<ResourceSearchPage> createState() => _ResourceSearchPageState();
}

class _ResourceSearchPageState extends State<ResourceSearchPage> {
  final TextEditingController _keyword = TextEditingController();
  final List<ResourceResult> _results = [];
  String? _progress;
  bool _searching = false;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _keyword.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入书名或关键词')),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results.clear();
      _progress = '准备…';
    });
    final service = context.read<ResourceSearchService>();
    final list = await service.search(
      kw,
      maxParse: 8,
      onProgress: (m) {
        if (mounted) setState(() => _progress = m);
      },
    );
    if (mounted) {
      setState(() {
        _results.addAll(list);
        _searching = false;
        _progress = null;
      });
    }
  }

  /// 加入书架（可选立即播放）。返回是否成功。
  Future<bool> _shelve(ResourceResult r, {bool play = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final audio = r.audioItems;
    if (audio.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('该分享里没有音频文件')));
      return false;
    }
    final book = DriveItem.folderToBook(
      folderName: r.title,
      audioFiles: audio,
      driveType: DriveType.quark,
      bookId: DriveItem.bookIdFor(DriveType.quark, r.shareUrl),
      shareUrl: r.shareUrl,
    );
    final repo = context.read<BookshelfRepository>();
    final player = context.read<AudioPlayerService>();
    await repo.add(BookshelfBook(
      id: book.id,
      title: book.title,
      author: book.author,
      chapterCount: book.chapters.length,
      driveType: DriveType.quark,
      isFromShare: true,
      shareUrl: r.shareUrl,
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
            : '「${book.title}」已加入书架（${book.chapters.length} 集）'),
      ));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('全网搜书')),
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
          Expanded(
            child: _results.isEmpty && !_searching
                ? const Center(
                    child: Text('从夸克网盘分享中搜索有声书\n结果可加入书架或直接播放',
                        textAlign: TextAlign.center))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) => _buildCard(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(ResourceResult r) {
    final theme = Theme.of(context);
    final inShelf = context
        .read<BookshelfRepository>()
        .isInShelf(DriveItem.bookIdFor(DriveType.quark, r.shareUrl));
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
                  if (!inShelf)
                    IconButton(
                      icon: const Icon(Icons.add_rounded),
                      tooltip: '加入书架',
                      onPressed: () => _shelve(r),
                    ),
                  IconButton(
                    icon: const Icon(Icons.play_arrow_rounded),
                    tooltip: '播放',
                    onPressed: () => _shelve(r, play: true),
                  ),
                ],
              ),
      ),
    );
  }

  String _sourceLabel(String source) {
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
