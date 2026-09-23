import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';

/// Service for importing local audio files into the bookshelf.
class LocalImportService {
  final BookshelfRepository _bookshelfRepo;

  LocalImportService(this._bookshelfRepo);

  /// Opens the file picker and imports selected audio file(s).
  /// Returns the imported book if successful, null if cancelled.
  ///
  /// 支持一次选择多个文件：多选时整批作为「一本书」导入，并按文件名
  /// 自然序排列（第 2 集 < 第 10 集），沿用网盘目录的排序实现。
  Future<Book?> importAudioFile() async {
    // file_picker 12 起 pickFiles 默认就支持多选，不必再传已废弃的
    // allowMultiple；取消时返回空列表。
    final picked = await FilePicker.pickFiles(
      type: FileType.audio,
    );
    final files =
        picked.where((f) => f.path != null && f.path!.isNotEmpty).toList();
    if (files.isEmpty) return null;

    // 多选时标题取「公共前缀」，退化到第一个文件名，避免出现奇怪的书名。
    files.sort((a, b) => DriveItem.compareNatural(a.name, b.name));
    final first = files.first;
    final title = files.length == 1 ? _stripExtension(first.name) : _commonRoot(files);

    final bookId = 'local_${DateTime.now().millisecondsSinceEpoch}';

    final chapters = files
        .map((f) => Chapter(
              filename: f.path!,
              title: _stripExtension(f.name),
              duration: Duration.zero,
              format: f.extension,
            ))
        .toList();

    final book = Book(
      id: bookId,
      title: title,
      author: '本地导入',
      chapters: chapters,
    );

    // Add to bookshelf
    await _bookshelfRepo.add(BookshelfBook(
      id: bookId,
      title: title,
      author: '本地导入',
      isLocal: true,
      localFilePath: first.path,
      chapterCount: chapters.length,
    ));

    return book;
  }

  /// 从多个文件名里取公共前缀作为书名（去掉尾部相连的分隔符与卷集号）。
  String _commonRoot(List<PlatformFile> files) {
    if (files.length == 1) return _stripExtension(files.first.name);
    var prefix = _stripExtension(files.first.name);
    for (final f in files.skip(1)) {
      final name = _stripExtension(f.name);
      var i = 0;
      while (i < prefix.length && i < name.length && prefix[i] == name[i]) {
        i++;
      }
      prefix = prefix.substring(0, i);
      if (prefix.isEmpty) break;
    }
    final trimmed = prefix.replaceAll(RegExp(r'[\s\-_第\d集章节]+$'), '').trim();
    return trimmed.isEmpty ? _stripExtension(files.first.name) : trimmed;
  }

  String _stripExtension(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0) {
      return fileName.substring(0, dotIndex);
    }
    return fileName;
  }
}
