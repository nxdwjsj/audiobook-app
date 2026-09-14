import 'package:hive/hive.dart';

part 'listen_session.g.dart';

/// 一次收听会话：每次手动点播新建一条，自动连播/上下章只更新本条。
/// 历史页数据源——能看到“几点开始听、听到第几章”。
@HiveType(typeId: 3)
class ListenSession {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String bookId;

  @HiveField(2)
  final String bookTitle;

  /// 会话开始时间（手动点播的时刻）。
  @HiveField(3)
  final DateTime startedAt;

  /// 最近一次进度更新的时间。
  @HiveField(4)
  final DateTime updatedAt;

  /// 当前听到的章节（0 起）。
  @HiveField(5)
  final int chapterIndex;

  @HiveField(6)
  final int positionSeconds;

  @HiveField(7)
  final int? chapterCount;

  /// 章节标题（历史页展示用）。
  @HiveField(8)
  final String? chapterTitle;

  ListenSession({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.startedAt,
    required this.updatedAt,
    required this.chapterIndex,
    required this.positionSeconds,
    this.chapterCount,
    this.chapterTitle,
  });

  /// 追加进度（不换会话）。
  ListenSession copyWithProgress({
    required int chapterIndex,
    required int positionSeconds,
    String? chapterTitle,
  }) =>
      ListenSession(
        id: id,
        bookId: bookId,
        bookTitle: bookTitle,
        startedAt: startedAt,
        updatedAt: DateTime.now(),
        chapterIndex: chapterIndex,
        positionSeconds: positionSeconds,
        chapterCount: chapterCount,
        chapterTitle: chapterTitle ?? this.chapterTitle,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'chapterIndex': chapterIndex,
        'positionSeconds': positionSeconds,
        'chapterCount': chapterCount,
        'chapterTitle': chapterTitle,
      };

  factory ListenSession.fromJson(Map<String, dynamic> json) => ListenSession(
        id: json['id'] as String,
        bookId: json['bookId'] as String,
        bookTitle: json['bookTitle'] as String? ?? '',
        startedAt: json['startedAt'] != null
            ? DateTime.parse(json['startedAt'] as String)
            : DateTime.now(),
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'] as String)
            : DateTime.now(),
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
        positionSeconds: (json['positionSeconds'] as num?)?.toInt() ?? 0,
        chapterCount: (json['chapterCount'] as num?)?.toInt(),
        chapterTitle: json['chapterTitle'] as String?,
      );
}
