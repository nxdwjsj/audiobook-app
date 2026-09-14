import 'book.dart';
import 'chapter.dart';

/// Supported cloud drive providers.
enum DriveType { baidu, quark }

/// Represents a file or folder in a cloud drive.
class DriveItem {
  /// Unique file identifier from the drive provider.
  final String fileId;

  /// Display name.
  final String name;

  /// Full path in the drive (e.g. /有声书/三体/).
  final String path;

  /// Whether this item is a directory.
  final bool isDir;

  /// File size in bytes (0 for directories).
  final int size;

  /// File extension without dot (e.g. "mp3").
  final String? extension;

  /// Parent directory path.
  final String parentPath;

  /// Whether this is a playable media file based on extension.
  /// Includes audiobook formats (m4b), video files (mp4/mkv) that carry
  /// audio streams, and lossless formats.
  final bool isAudio;

  /// Number of items inside this folder (0 if unknown or a file).
  final int fileCount;

  DriveItem({
    required this.fileId,
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.extension,
    this.parentPath = '',
    this.fileCount = 0,
  }) : isAudio = _isAudioFile(name);

  static bool _isAudioFile(String name) {
    const audioExtensions = [
      'mp3', 'm4a', 'm4b', 'm4r', 'wav', 'flac', 'aac', 'ogg',
      'wma', 'opus', 'aiff', 'aif', 'ape', 'mp4', 'mkv', 'webm',
      'mov', 'ts',
    ];
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0) return false;
    final ext = name.substring(dotIndex + 1).toLowerCase();
    return audioExtensions.contains(ext);
  }

  /// Build a stable book id for a cloud drive book.
  ///
  /// [key] is the folder path for own-drive books, or the share title for
  /// share-link books. Using the same key in the browser and on the shelf
  /// keeps playback progress consistent.
  static String bookIdFor(DriveType driveType, String key) {
    final normalized =
        key.trim().replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/|/$'), '');
    return 'drive_${driveType.name}_$normalized';
  }

  /// Build a Book from a list of audio DriveItems (chapters).
  /// The folder name becomes the book title.
  static Book folderToBook({
    required String folderName,
    required List<DriveItem> audioFiles,
    required DriveType driveType,
    required String bookId,
    String? shareUrl,
  }) {
    // Natural sort so "1.mp3, 2.mp3, 10.mp3" keeps the intended order.
    final sorted = List<DriveItem>.from(audioFiles)
      ..sort((a, b) => compareNatural(a.name, b.name));

    return Book(
      id: bookId,
      title: folderName,
      author: driveType == DriveType.baidu ? '百度网盘' : '夸克网盘',
      chapters: sorted
          .map((f) => Chapter.fromDriveItem(f, driveType, shareUrl: shareUrl))
          .toList(),
    );
  }

  /// Compare two file names in "natural" order, treating runs of digits
  /// as numbers (chapter_2 < chapter_10).
  static int compareNatural(String a, String b) {
    final ta = _tokenize(a);
    final tb = _tokenize(b);
    final len = ta.length < tb.length ? ta.length : tb.length;
    for (var i = 0; i < len; i++) {
      final x = ta[i];
      final y = tb[i];
      final cmp = (x is int && y is int)
          ? x.compareTo(y)
          : x.toString().toLowerCase().compareTo(y.toString().toLowerCase());
      if (cmp != 0) return cmp;
    }
    return ta.length.compareTo(tb.length);
  }

  static List<Object> _tokenize(String s) {
    final tokens = <Object>[];
    final buf = StringBuffer();
    bool? prevIsDigit;
    for (final ch in s.split('')) {
      final isDigit = ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;
      if (prevIsDigit == null || isDigit == prevIsDigit) {
        buf.write(ch);
      } else {
        _flushToken(tokens, buf.toString(), prevIsDigit);
        buf
          ..clear()
          ..write(ch);
      }
      prevIsDigit = isDigit;
    }
    if (buf.isNotEmpty && prevIsDigit != null) {
      _flushToken(tokens, buf.toString(), prevIsDigit);
    }
    return tokens;
  }

  static void _flushToken(List<Object> tokens, String text, bool isDigit) {
    tokens.add(isDigit ? (int.tryParse(text) ?? text) : text);
  }

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'name': name,
        'path': path,
        'isDir': isDir,
        'size': size,
        'extension': extension,
        'parentPath': parentPath,
      };

  factory DriveItem.fromJson(Map<String, dynamic> json) => DriveItem(
        fileId: json['fileId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDir: json['isDir'] as bool? ?? false,
        size: (json['size'] as num?)?.toInt() ?? 0,
        extension: json['extension'] as String?,
        parentPath: json['parentPath'] as String? ?? '',
      );
}
