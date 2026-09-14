import 'package:hive/hive.dart';

part 'bookmark.g.dart';

@HiveType(typeId: 0)
class Bookmark {
  @HiveField(0)
  final String bookId;

  @HiveField(1)
  final String bookTitle;

  @HiveField(2)
  final int chapterIndex;

  @HiveField(3)
  final String chapterTitle;

  @HiveField(4)
  final int positionSeconds;

  @HiveField(5)
  final DateTime createdAt;

  @HiveField(6)
  final String? note;

  Bookmark({
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.positionSeconds,
    DateTime? createdAt,
    this.note,
  }) : createdAt = createdAt ?? DateTime.now();

  Duration get position => Duration(seconds: positionSeconds);

  String get id => '${bookId}_${chapterIndex}_${positionSeconds}_${createdAt.millisecondsSinceEpoch}';

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'bookTitle': bookTitle,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'positionSeconds': positionSeconds,
        'createdAt': createdAt.toIso8601String(),
        'note': note,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        bookId: json['bookId'] as String,
        bookTitle: json['bookTitle'] as String,
        chapterIndex: (json['chapterIndex'] as num).toInt(),
        chapterTitle: json['chapterTitle'] as String,
        positionSeconds: (json['positionSeconds'] as num).toInt(),
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'] as String)
            : DateTime.now(),
        note: json['note'] as String?,
      );
}
