import 'dart:async';
import '../models/drive_item.dart';

/// Authentication status for a cloud drive.
enum AuthStatus { unauthenticated, authenticated, expired }

/// Result of parsing a share link.
class ShareParseResult {
  final List<DriveItem> items;
  final String? folderName;

  const ShareParseResult({required this.items, this.folderName});
}

/// A resolved streamable audio URL together with the HTTP headers
/// required to fetch it (some providers reject requests without
/// a browser User-Agent / Referer / Cookie).
class ResolvedStream {
  final String url;
  final Map<String, String>? headers;

  const ResolvedStream(this.url, {this.headers});
}

/// Abstract interface for cloud drive services (Baidu / Quark).
///
/// Implementations must handle:
/// - Authentication (OAuth for Baidu, Cookie for Quark)
/// - File listing (Scheme A: browse own drive)
/// - Share link parsing (Scheme B: parse shared resources)
/// - Audio stream URL fetching (real-time, links expire)
abstract class CloudDriveService {
  /// The drive provider type.
  DriveType get driveType;

  /// Current authentication status.
  AuthStatus get authStatus;

  /// Initialize the service (load saved credentials).
  Future<void> init();

  /// Start login flow. Returns true if login was initiated.
  /// For Baidu: opens OAuth page. For Quark: expects cookie to be set.
  Future<bool> login();

  /// Log out and clear credentials.
  Future<void> logout();

  /// List files in a directory.
  /// [path] defaults to root ('/').
  /// [dirFileId] is the provider file id of the directory, when known
  /// (Quark navigates by fid; Baidu ignores it and uses [path]).
  Future<List<DriveItem>> listFolder({String path = '/', String? dirFileId});

  /// Parse a shared link and return the contained files.
  /// [shareUrl] the share link, [pwd] optional extraction code.
  Future<ShareParseResult> parseShareLink(String shareUrl, {String? pwd});

  /// Get a real-time streamable URL for an audio file in the user's own drive.
  /// Links may expire, so call this right before playback.
  Future<ResolvedStream> getAudioStreamUrl(String fileId);

  /// Get a real-time streamable URL for a file inside a shared link.
  /// [shareUrl] must have been parsed before (or is re-parsed on demand).
  Future<ResolvedStream> getShareAudioStreamUrl(String shareUrl, String fileId);

  /// Get user account info (nickname, used space, etc.).
  Future<Map<String, dynamic>> getAccountInfo();
}
