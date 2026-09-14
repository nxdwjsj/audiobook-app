import 'drive_item.dart';

/// Represents a single chapter (audio file) of an audiobook.
class Chapter {
  final String filename;
  final String title;
  final Duration duration;
  final String? format;

  /// Cloud drive file ID (for fetching stream URL).
  final String? fileId;

  /// Cloud drive provider type.
  final DriveType? driveType;

  /// Share link this chapter belongs to (null for own-drive chapters).
  final String? shareUrl;

  const Chapter({
    required this.filename,
    required this.title,
    required this.duration,
    this.format,
    this.fileId,
    this.driveType,
    this.shareUrl,
  });

  /// Create a Chapter from a cloud drive file item.
  factory Chapter.fromDriveItem(
    DriveItem item,
    DriveType driveType, {
    String? shareUrl,
  }) {
    final dotIndex = item.name.lastIndexOf('.');
    final title = dotIndex > 0 ? item.name.substring(0, dotIndex) : item.name;
    return Chapter(
      filename: item.name,
      title: title.replaceAll(RegExp(r'[_]'), ' ').trim(),
      duration: Duration.zero,
      format: item.extension,
      fileId: item.fileId,
      driveType: driveType,
      shareUrl: shareUrl,
    );
  }

  factory Chapter.fromJson(Map<String, dynamic> json) {
    final lengthStr = json['length']?.toString() ?? '0';
    final seconds = double.tryParse(lengthStr) ?? 0;

    // Title: prefer "title" field, otherwise derive from filename
    String title = json['title']?.toString() ?? json['name']?.toString() ?? 'Chapter';
    if (title.endsWith('.mp3')) {
      title = title.substring(0, title.length - 4);
    }
    // Clean up title
    title = title.replaceAll(RegExp(r'[_]'), ' ').trim();

    final driveTypeStr = json['driveType']?.toString();
    return Chapter(
      filename: json['name']?.toString() ?? '',
      title: title,
      duration: Duration(seconds: seconds.toInt()),
      format: json['format']?.toString(),
      fileId: json['fileId']?.toString(),
      // Unknown provider -> null, so we never silently call the wrong drive.
      driveType: driveTypeStr == null
          ? null
          : DriveType.values.where((e) => e.name == driveTypeStr).firstOrNull,
      shareUrl: json['shareUrl']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': filename,
        'title': title,
        'length': duration.inSeconds,
        'format': format,
        'fileId': fileId,
        'driveType': driveType?.name,
        'shareUrl': shareUrl,
      };
}
