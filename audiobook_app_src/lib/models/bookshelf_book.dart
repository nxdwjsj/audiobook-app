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
        'chapters': chapters?.map((c) => c.toJson()).toList(),
        'sortOrder': sortOrder,
        'localCoverPath': localCoverPath,
      };

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
