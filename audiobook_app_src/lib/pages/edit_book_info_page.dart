import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/bookshelf_book.dart';
import '../repositories/bookshelf_repository.dart';
/// 编辑书籍信息：封面（从相册选图）、作者、简介。
/// 封面复制到 App 私有目录持久保存，避免原图被删后失效。
class EditBookInfoPage extends StatefulWidget {
  final String bookId;

  const EditBookInfoPage({super.key, required this.bookId});

  @override
  State<EditBookInfoPage> createState() => _EditBookInfoPageState();
}

class _EditBookInfoPageState extends State<EditBookInfoPage> {
  final _authorController = TextEditingController();
  final _descController = TextEditingController();
  BookshelfBook? _book;
  String? _coverPath;

  @override
  void initState() {
    super.initState();
    _book = context.read<BookshelfRepository>().getById(widget.bookId);
    _authorController.text = _book?.author ?? '';
    _descController.text = _book?.description ?? '';
    _coverPath = _book?.localCoverPath;
  }

  @override
  void dispose() {
    _authorController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null || file.path == null) return;
    final src = File(file.path!);
    // 复制到 App 文档目录下的 covers/，保证持久
    final docsDir = await _docsDir();
    final coversDir = Directory('${docsDir.path}/covers');
    if (!await coversDir.exists()) {
      await coversDir.create(recursive: true);
    }
    final ext = src.path.contains('.') ? src.path.split('.').last : 'jpg';
    // 网盘书的 bookId 含路径（如 drive_quark_a/b），需清洗分隔符再做文件名，
    // 否则会因中间目录不存在导致复制失败、封面静默丢失
    final safeId = widget.bookId
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    final shortId = safeId.length > 60 ? safeId.substring(0, 60) : safeId;
    final dst = File(
        '${coversDir.path}/${shortId}_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await src.copy(dst.path);
    // 清理旧封面
    if (_coverPath != null && _coverPath!.startsWith(coversDir.path)) {
      final old = File(_coverPath!);
      if (await old.exists()) await old.delete();
    }
    setState(() => _coverPath = dst.path);
  }

  Future<Directory> _docsDir() => getApplicationDocumentsDirectory();

  Future<void> _save() async {
    final repo = context.read<BookshelfRepository>();
    final book = _book;
    if (book == null) return;
    await repo.update(BookshelfBook(
      id: book.id,
      title: book.title,
      author: _authorController.text.trim().isEmpty
          ? null
          : _authorController.text.trim(),
      coverUrl: book.coverUrl,
      description:
          _descController.text.trim().isEmpty ? null : _descController.text.trim(),
      chapterCount: book.chapterCount,
      isLocal: book.isLocal,
      localFilePath: book.localFilePath,
      addedAt: book.addedAt,
      driveType: book.driveType,
      drivePath: book.drivePath,
      driveDirFid: book.driveDirFid,
      isFromShare: book.isFromShare,
      shareUrl: book.shareUrl,
      // 刻意不传 chapters：本页只改元信息（封面/作者/简介）。传 null 表示
      // 「本次不涉及章节」，repo 就不会重写 chapters box —— 这正是 PERF-01
      // 消除写放大的关键（改封面不再重写上千条章节）。
      sortOrder: book.sortOrder,
      localCoverPath: _coverPath,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑信息'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 封面
          Center(
            child: GestureDetector(
              onTap: _pickCover,
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 130,
                      height: 184,
                      child: _coverPath != null
                          ? Image.file(File(_coverPath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const _CoverFallback())
                          : const _CoverFallback(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _coverPath == null ? '点击选择封面' : '点击更换封面',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _authorController,
            decoration: const InputDecoration(
              labelText: '作者',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descController,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '简介',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.add_a_photo_rounded, size: 40)),
    );
  }
}
