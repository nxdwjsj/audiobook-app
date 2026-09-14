import 'package:file_picker/file_picker.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../repositories/bookshelf_repository.dart';

/// Service for importing local audio files into the bookshelf.
class LocalImportService {
  final BookshelfRepository _bookshelfRepo;

  LocalImportService(this._bookshelfRepo);

  /// Opens the file picker and imports selected audio file(s).
  /// Returns the imported book if successful, null if cancelled.
  Future<Book?> importAudioFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.audio,
    );

    if (file == null) return null;

    final path = file.path;
    if (path == null) return null;

    final fileName = file.name;
    final bookId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    final title = _stripExtension(fileName);

    final book = Book(
      id: bookId,
      title: title,
      author: '本地导入',
      chapters: [
        Chapter(
          filename: path,
          title: title,
          duration: Duration.zero,
          format: file.extension,
        ),
      ],
    );

    // Add to bookshelf
    await _bookshelfRepo.add(BookshelfBook(
      id: bookId,
      title: title,
      author: '本地导入',
      isLocal: true,
      localFilePath: path,
      chapterCount: 1,
    ));

    return book;
  }

  String _stripExtension(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0) {
      return fileName.substring(0, dotIndex);
    }
    return fileName;
  }
}
