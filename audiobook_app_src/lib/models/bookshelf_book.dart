import 'package:hive/hive.dart';
import 'chapter.dart';
import 'drive_item.dart';

part 'bookshelf_book.g.dart';

/// A book stored in the user's bookshelf (local persistence).
@HiveType(typeId: 2)
class BookshelfBook {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String? author;

  @HiveField(3)
  final String? coverUrl;

  @HiveField(4)
  final String? description;

  /// Number of chapters, used for progress display.
  @HiveField(5)
  final int chapterCount;

  /// Whether this book was imported locally (not from LibriVox).
  @HiveField(6)
  final bool isLocal;

  /// Local file path for imported books.
  @HiveField(7)
  final String? localFilePath;

  @HiveField(8)
  final DateTime addedAt;

  /// Cloud drive provider (null for non-drive books).
  @HiveField(10)
  final DriveType? driveType;

  /// Path in the cloud drive (for re-listing chapters).
  @HiveField(11)
  final String? drivePath;

  /// Folder file ID (Quark) for fast navigation back into the folder.
  @HiveField(14)
  final String? driveDirFid;

  /// Whether this book comes from a shared link.
  @HiveField(12)
  final bool isFromShare;

  /// Share URL if from a shared link.
  @HiveField(13)
  final String? shareUrl;

  /// Cached chapter list for drive books.
  /// When non-null, playback can be started directly without re-listing
  /// the drive folder (avoids unnecessary API calls on the shelf).
  ///
  /// **已迁移（PERF-01）**：新写入不再把章节内嵌到本记录，改存独立的
  /// `chapters` box（见 `StorageService.chapters` / `BookshelfRepository.getChapters`）。
  /// 该字段仅作为**旧数据的回落读取来源**保留，不做清理，
  /// 因此老版本 App 仍能读到旧数据（回滚零成本）。
  /// 新的序列化产物里不再包含 `chapters` 键。
  @Deprecated('章节已拆到独立 chapters box，读取请用 BookshelfRepository.getChapters')
  @HiveField(9)
  final List<Chapter>? chapters;

  /// Manual sort order (smaller = first). Null = sort by addedAt.
  @HiveField(15)
  final int? sortOrder;

  /// Custom cover image local path (user-picked from gallery).
  @HiveField(16)
  final String? localCoverPath;

  BookshelfBook({
    required this.id,
    required this.title,
    this.author,
    this.coverUrl,
    this.description,
    this.chapterCount = 1,
    this.isLocal = false,
    this.localFilePath,
    DateTime? addedAt,
    this.driveType,
    this.drivePath,
    this.driveDirFid,
    this.isFromShare = false,
    this.shareUrl,
    this.chapters,
    this.sortOrder,
    this.localCoverPath,
  }) : addedAt = addedAt ?? DateTime.now();

  /// 序列化书记录。
  ///
  /// **不再输出 `chapters`**（PERF-01）：章节已拆到独立的 `chapters` box，
  /// 由 `BookshelfRepository` 单独读写。这样改一次封面等元信息只需写这条
  /// 约 300B 的记录，不必把上千条章节整段重新序列化。
  ///
  /// 注意：这是"新写入不带 chapters"，并不是"清理旧数据"——历史记录里
  /// 内嵌的 `chapters` 键原样保留，[fromJson] 也仍然会读它，保证双读与回滚。
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'description': description,
        'chapterCount': chapterCount,
        'isLocal': isLocal,
        'localFilePath': localFilePath,
        'addedAt': addedAt.toIso8601String(),
        'driveType': driveType?.name,
        'drivePath': drivePath,
        'driveDirFid': driveDirFid,
        'isFromShare': isFromShare,
        'shareUrl': shareUrl,
        'sortOrder': sortOrder,
        'localCoverPath': localCoverPath,
      };

  /// 复制一份并替换章节（章节拆表后，`getById` 用它把独立 box 里的章节
  /// 补回对象上，保持调用方行为不变）。
  BookshelfBook withChapters(List<Chapter>? chapters) {
    return BookshelfBook(
      id: id,
      title: title,
      author: author,
      coverUrl: coverUrl,
      description: description,
      chapterCount: chapterCount,
      isLocal: isLocal,
      localFilePath: localFilePath,
      addedAt: addedAt,
      driveType: driveType,
      drivePath: drivePath,
      driveDirFid: driveDirFid,
      isFromShare: isFromShare,
      shareUrl: shareUrl,
      // ignore: deprecated_member_use_from_same_package
      chapters: chapters,
      sortOrder: sortOrder,
      localCoverPath: localCoverPath,
    );
  }

  factory BookshelfBook.fromJson(Map<String, dynamic> json) {
    final driveTypeStr = json['driveType']?.toString();
    DriveType? driveType;
    if (driveTypeStr != null) {
      try {
        driveType = DriveType.values.firstWhere((e) => e.name == driveTypeStr);
      } catch (_) {
        driveType = null; // silently ignore unknown values
      }
    }
    final chaptersJson = json['chapters'] as List<dynamic>?;
    final chapters = chaptersJson
        ?.map((c) => Chapter.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    return BookshelfBook(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String?,
      coverUrl: json['coverUrl'] as String?,
      description: json['description'] as String?,
      chapterCount: (json['chapterCount'] as num?)?.toInt() ?? 1,
      isLocal: json['isLocal'] as bool? ?? false,
      localFilePath: json['localFilePath'] as String?,
      addedAt: json['addedAt'] != null
          ? DateTime.parse(json['addedAt'] as String)
          : DateTime.now(),
      driveType: driveType,
      drivePath: json['drivePath'] as String?,
      driveDirFid: json['driveDirFid'] as String?,
      isFromShare: json['isFromShare'] as bool? ?? false,
      shareUrl: json['shareUrl'] as String?,
      chapters: chapters,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      localCoverPath: json['localCoverPath'] as String?,
    );
  }
}
