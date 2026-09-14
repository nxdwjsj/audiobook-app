import 'chapter.dart';

/// Represents an audiobook loaded into the player.
///
/// This is a lightweight in-memory model: drive books are built via
/// [DriveItem.folderToBook] and local books via [LocalImportService].
/// It carries no network/source-specific parsing.
class Book {
  final String id;
  final String title;
  final String? author;
  final String? description;
  final String? coverUrl;
  final String? language;
  final String? releaseDate;
  final List<Chapter> chapters;

  const Book({
    required this.id,
    required this.title,
    this.author,
    this.description,
    this.coverUrl,
    this.language,
    this.releaseDate,
    this.chapters = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'description': description,
        'coverUrl': coverUrl,
        'language': language,
        'releaseDate': releaseDate,
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };

  Book copyWith({
    String? id,
    String? title,
    String? author,
    String? description,
    String? coverUrl,
    String? language,
    String? releaseDate,
    List<Chapter>? chapters,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      language: language ?? this.language,
      releaseDate: releaseDate ?? this.releaseDate,
      chapters: chapters ?? this.chapters,
    );
  }
}
