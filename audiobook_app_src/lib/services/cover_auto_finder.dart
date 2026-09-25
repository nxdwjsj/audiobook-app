import '../models/bookshelf_book.dart';
import '../models/drive_item.dart';
import '../repositories/bookshelf_repository.dart';
import 'book_cover_service.dart';
import 'cloud_drive_service.dart';
import 'storage_service.dart';

/// 按网盘类型取对应服务（UI 层用 Provider 提供，便于测试注入假实现）。
typedef DriveResolver = CloudDriveService? Function(DriveType type);

/// 封面自动发现（设计规范 §4.4）。
///
/// 网盘有声书目录里常常就躺着一张 `cover.jpg` / `folder.jpg`，
/// 但书架此前从不去看它 —— 封面一栏长期空着，全靠生成封面顶。
///
/// 策略：
/// 1. 已有 `localCoverPath` → 跳过（用户自选的最高优先级，不能覆盖）；
/// 2. 本地已缓存发现到的封面 → 直接回补路径；
/// 3. 列一遍目录，按文件名挑封面图（`cover` / `folder` / `封面` …），
///    下载到 `<docs>/covers`，**落盘**而不是记 URL（直链会过期）；
/// 4. 找不到 → 退而本地渲染生成封面（零网络）。
///
/// 三种产物用文件名区分：发现的封面是 `{id}.jpg/png/webp`，
/// 生成的是 `{id}.gen.png`。所以「先生成过」不会挡住以后网盘里出现真封面。
class CoverAutoFinder {
  CoverAutoFinder({
    required this.storage,
    required this.repository,
    this.driveOf,
    this.maxPerRun = 12,
    this.concurrency = 2,
  });

  final StorageService storage;
  final BookshelfRepository repository;
  final DriveResolver? driveOf;

  /// 一轮处理上限：大书架不该在进页面时一口气拉几十次网盘。
  final int maxPerRun;

  /// 并发上限：网盘 API 有频率限制，2 个足够快又不至于触发风控。
  final int concurrency;

  static const Set<String> _imageExt = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
  };

  /// 明确的封面名（不含扩展名）优先于"目录里随便一张图"。
  static const List<String> _coverNames = <String>[
    'cover',
    'folder',
    'album',
    'poster',
    'front',
    '封面',
    '书封',
  ];

  static const String _generatedSuffix = 'gen.png';

  /// 取扩展名（不含点，小写）；没有返回 null。
  static String? extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return null;
    return name.substring(i + 1).toLowerCase();
  }

  static bool isImageName(String name) {
    final ext = extOf(name);
    return ext != null && _imageExt.contains(ext);
  }

  /// 从目录列表里挑封面文件：明确的封面名优先，其次任意图片。
  ///
  /// 抽成纯函数是为了能直接测 —— 这条规则的边界（扩展名大小写、
  /// `cover.jpg` 与 `cover_back.jpg` 谁优先）肉眼很难保证一致。
  static DriveItem? pickCoverFile(List<DriveItem> items) {
    DriveItem? fallback;
    for (final item in items) {
      if (item.isDir || !isImageName(item.name)) continue;
      final stem = _stemOf(item.name);
      for (final wanted in _coverNames) {
        if (stem == wanted) return item; // 完全命中，立刻返回
      }
      // 宽松命中：`cover.jpg` 之外的 `cover_front.jpg` 也算，但排在后面
      fallback ??= item;
    }
    return fallback;
  }

  static String _stemOf(String name) {
    final i = name.lastIndexOf('.');
    return (i <= 0 ? name : name.substring(0, i)).trim().toLowerCase();
  }

  static String _fsSafe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 一轮略过：挑出需要处理的书，并发处理，命中后回写 repository。
  ///
  /// [alreadyTried] 由调用方维护（页面生命周期内的去重），避免同一个 Bookshelf
  /// 重建周期里对同一本书反复起任务。
  Future<void> run(
    List<BookshelfBook> books, {
    required Set<String> alreadyTried,
  }) async {
    final queue = <BookshelfBook>[];
    for (final book in books) {
      if (queue.length >= maxPerRun) break;
      if (alreadyTried.contains(book.id)) continue;
      if (_hasCover(book)) continue;
      // 已经联网找过且失败的书，只在本地没封面（连生成封面都没有）时才重试
      final generatedKey = '${_fsSafe(book.id)}.$_generatedSuffix';
      if (storage.isCoverProbed(book.id) &&
          await BookCoverService.cacheExists(generatedKey)) {
        continue;
      }
      alreadyTried.add(book.id);
      queue.add(book);
    }
    if (queue.isEmpty) return;

    // 简易并发窗口：不引第三方 FuturePool，够用且可读
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < queue.length) {
        final index = cursor++;
        if (index >= queue.length) return;
        final book = queue[index];
        final path = await ensureCover(book);
        if (path != null) {
          await repository.update(book.withCoverPath(path));
        } else {
          await storage.markCoverProbed(book.id);
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < concurrency; i++) worker(),
    ];
    await Future.wait(workers);
  }

  static bool _hasCover(BookshelfBook book) {
    final p = book.localCoverPath;
    return p != null && p.isNotEmpty;
  }

  /// 为单本书准备封面文件，返回落盘路径；拿不到返回 null。
  Future<String?> ensureCover(BookshelfBook book) async {
    final key = _fsSafe(book.id);

    // 1) 以前发现过并落盘的封面（三种扩展名任一）
    for (final ext in const ['jpg', 'png', 'webp']) {
      if (await BookCoverService.cacheExists('$key.$ext')) {
        final dir = await BookCoverService.coversDir();
        return '${dir.path}/$key.$ext';
      }
    }

    // 2) 去网盘目录里找
    final found = await _findInDrive(book, key);
    if (found != null) return found;

    // 3) 兜底：本地渲染生成封面并缓存
    final genKey = '$key.$_generatedSuffix';
    if (await BookCoverService.cacheExists(genKey)) {
      final dir = await BookCoverService.coversDir();
      return '${dir.path}/$genKey';
    }
    final bytes = await BookCoverService.renderGeneratedCover(
      title: book.title,
      author: book.author,
    );
    if (bytes == null) return null;
    return BookCoverService.saveCoverBytes(genKey, bytes);
  }

  Future<String?> _findInDrive(BookshelfBook book, String key) async {
    final type = book.driveType;
    final drive = type == null ? null : driveOf?.call(type);
    if (drive == null) return null;
    final fid = book.driveDirFid;
    final bookPath = book.drivePath;
    if ((fid == null || fid.isEmpty) && (bookPath == null || bookPath.isEmpty)) {
      return null;
    }
    List<DriveItem> items;
    try {
      items = await drive.listFolder(
        path: bookPath ?? '/',
        dirFileId: (fid == null || fid.isEmpty) ? null : fid,
      );
    } catch (_) {
      return null;
    }
    final candidate = pickCoverFile(items);
    if (candidate == null) return null;

    ResolvedStream stream;
    try {
      stream = await drive.getAudioStreamUrl(candidate.fileId);
    } catch (_) {
      return null;
    }
    final bytes = await BookCoverService.downloadCover(stream);
    if (bytes == null) return null;
    return BookCoverService.saveCoverBytes(
      '$key.${BookCoverService.extensionFor(bytes)}',
      bytes,
    );
  }
}
