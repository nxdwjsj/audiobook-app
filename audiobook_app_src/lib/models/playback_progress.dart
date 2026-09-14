import 'package:hive/hive.dart';

part 'playback_progress.g.dart';

@HiveType(typeId: 1)
class PlaybackProgress {
  @HiveField(0)
  final String bookId;

  @HiveField(1)
  final int chapterIndex;

  @HiveField(2)
  final int positionSeconds;

  @HiveField(3)
  final DateTime updatedAt;

  /// Book title at save time — used by the history page for books
  /// that are no longer on the shelf.
  @HiveField(4)
  final String? bookTitle;

  /// Total chapter count at save time (for progress percentage).
  @HiveField(5)
  final int? chapterCount;

  PlaybackProgress({
    required this.bookId,
    required this.chapterIndex,
    required this.positionSeconds,
    DateTime? updatedAt,
    this.bookTitle,
    this.chapterCount,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Duration get position => Duration(seconds: positionSeconds);

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'positionSeconds': positionSeconds,
        'updatedAt': updatedAt.toIso8601String(),
        'bookTitle': bookTitle,
        'chapterCount': chapterCount,
      };

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) =>
      PlaybackProgress(
        bookId: json['bookId'] as String,
        chapterIndex: (json['chapterIndex'] as num).toInt(),
        positionSeconds: (json['positionSeconds'] as num).toInt(),
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'] as String)
            : DateTime.now(),
        bookTitle: json['bookTitle'] as String?,
        chapterCount: (json['chapterCount'] as num?)?.toInt(),
      );
}
