import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import '../services/audio_player_service.dart';
import '../services/quark_drive_service.dart';
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
  bool _shelving = false;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
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
      // 边解析边出结果，首条结果几秒内就能看到。
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _results.add(r);
          _results.sort(_compare);
        });
      },
    );
    if (mounted) {
      setState(() {
        _results
          ..clear()
          ..addAll(list);
        _searching = false;
        _progress = null;
      });
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

  /// 加入书架（可选立即播放）。返回是否成功。
  ///
  /// 夸克分享文件没有直链，必须先转存到自己的网盘，转存后的 fid 才能播放。
  Future<bool> _shelve(ResourceResult r, {bool play = false}) async {
    // 转存 + 入架期间锁住，连点会并发 playBook 并把播放页压两层
    if (_shelving) return false;
    final messenger = ScaffoldMessenger.of(context);
    final audio = r.audioItems;
    if (audio.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('该分享里没有音频文件')));
      return false;
    }
    setState(() => _shelving = true);
    try {
      final repo = context.read<BookshelfRepository>();
      final player = context.read<AudioPlayerService>();
      final quark = context.read<QuarkDriveService>();

      setState(() => _progress = '正在转存「${r.title}」到你的夸克网盘…');
      List<DriveItem> saved;
      try {
        saved = await quark.saveShareToMyDrive(r.shareUrl, pwd: r.passcode);
      } catch (e) {
        if (mounted) setState(() => _progress = null);
        messenger.showSnackBar(SnackBar(content: Text('转存失败：$e')));
        return false;
      }
      if (mounted) setState(() => _progress = null);
      if (saved.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('该分享里没有可播放的音频文件')));
        return false;
      }

      // 章节 fid 已是自己网盘的 fid，因此不再标记为分享文件（走普通下载直链）。
      final book = DriveItem.folderToBook(
        folderName: r.title,
        audioFiles: saved,
        driveType: DriveType.quark,
        bookId: DriveItem.bookIdFor(DriveType.quark, r.shareUrl),
      );
      await repo.add(BookshelfBook(
        id: book.id,
        title: book.title,
        author: book.author,
        chapterCount: book.chapters.length,
        driveType: DriveType.quark,
        isFromShare: false,
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
              : '「${book.title}」已转存并加入书架（${book.chapters.length} 集）'),
        ));
      }
      return true;
    } finally {
      if (mounted) setState(() => _shelving = false);
    }
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
                  if (_shelving)
                    // 转存期间给个明确的忙碌反馈，顺便锁住按钮
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
                        onPressed: () => _shelve(r),
                      ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded),
                      tooltip: '播放',
                      onPressed: () => _shelve(r, play: true),
                    ),
                  ],
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
