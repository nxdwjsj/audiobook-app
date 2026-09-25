import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_tokens.dart';
import '../widgets/book_cover.dart' show coverVerticalTitle;
import 'cloud_drive_service.dart' show ResolvedStream;

/// 封面文件的落地（设计规范 §4.4：自动封面发现 + 生成封面缓存）。
///
/// 两类封面最终都落成**本地文件**，再由 `BookCover` 当作 `customImagePath`
/// 加载。为什么不是"拿到 URL 直接显示"：
/// - 网盘的封面直链**带鉴权且会过期**（夸克注释里明确写了 "links expire"），
///   存 URL 意味着下次启动必然加载失败一次，然后再回落到生成封面；
/// - 生成封面每帧都要重排版式（Widget 树 + Text layout），落盘后变成一次
///   解码，书架滚动时差别肉眼可见。
class BookCoverService {
  BookCoverService._();

  /// 生成封面的渲染尺寸（3:4 竖版，约书架封面 dpr3 的显示大小）。
  static const int generatedWidth = 300;
  static const int generatedHeight = 400;

  /// 单个封面文件的大小上限：网盘目录里的 `folder.jpg` 可能是原图相册级别的
  /// 好几 MB，没必要为一张缩略图付这么多流量与内存。
  static const int maxCoverBytes = 4 * 1024 * 1024;

  /// 封面目录：`<应用文档>/covers`。
  static Future<Directory> coversDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/covers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 已缓存则不再重复找：`localCoverPath` 的存在本身就是"找过了"的证据。
  static Future<bool> cacheExists(String fileKey) async {
    final dir = await coversDir();
    return File('${dir.path}/$fileKey').exists();
  }

  /// 下载网盘封面并校验。失败一律返回 null（调用方回落生成封面）。
  ///
  /// [stream.headers] 必须带上：CDN 有防盗链，缺 UA 会直接 403。
  static Future<Uint8List?> downloadCover(ResolvedStream stream) async {
    try {
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
          headers: stream.headers,
          followRedirects: true,
        ),
      );
      final res = await dio.get<Uint8List>(stream.url);
      final bytes = res.data;
      if (bytes == null) return null;
      if (bytes.lengthInBytes < 64 || bytes.lengthInBytes > maxCoverBytes) {
        return null;
      }
      if (!looksLikeImage(bytes)) return null;
      return bytes;
    } catch (_) {
      // 网络/超时/403 一律静默回落，不打扰用户：封面缺失不影响听书
      return null;
    }
  }

  /// 按文件头判断是不是真图片（目录里常有同名但内容是 HTML 的假图）。
  ///
  /// 比起看扩展名，看 magic bytes 更可靠 —— 网盘里 `cover.jpg` 实际是
  /// 「网盘临时错误页」的情况并不罕见。
  static bool looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    // JPEG: FF D8 FF
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true;
    }
    // GIF: GIF87a / GIF89a
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    // WEBP: RIFF....WEBP
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true;
    }
    return false;
  }

  /// 按文件头挑扩展名，避免把 PNG 存成 .jpg（部分解码器会直接拒绝）。
  static String extensionFor(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'webp';
    }
    return 'jpg';
  }

  /// 写盘并返回路径。
  static Future<String?> saveCoverBytes(String key, Uint8List bytes) async {
    try {
      final dir = await coversDir();
      final file = File('${dir.path}/$key');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 离屏渲染「生成封面」为 PNG 字节（与 `_GeneratedCover` widget 同一版式）。
  ///
  /// 排版数学与 widget 保持一致：pad = 宽 7.5%、竖排标题占高 52%、
  /// 字号 `可用高度 ÷ 字数` 夹取到 12~34、作者行贴底。

  /// 任一步失败返回 null：**封面缓存是优化不是功能**，绝不能因为渲染失败
  /// 就让书变成没封面 —— 调用方会继续用 widget 版生成封面。
  static Future<Uint8List?> renderGeneratedCover({
    required String title,
    String? author,
    int width = generatedWidth,
    int height = generatedHeight,
  }) async {
    ui.Picture? picture;
    ui.Image? image;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final w = width.toDouble();
      final h = height.toDouble();
      final pad = w * 0.075;

      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()..color = AppCoverPalette.colorFor(title),
      );
      canvas.drawRect(
        Rect.fromLTWH(pad, pad, w - pad * 2, h - pad * 2),
        Paint()
          ..color = AppCoverPalette.frame
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5,
      );

      // 竖排书名：绘本式居中
      final chars = coverVerticalTitle(title, '书');
      final lines = chars.characters.length;
      final fontSize =
          ((h * 0.52) / (lines * 1.16)).clamp(12.0, 34.0).toDouble();
      final titlePara = (ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: TextAlign.center,
              fontSize: fontSize,
              height: 1.16,
              fontWeight: FontWeight.w500,
            ),
          )
                ..pushStyle(
                  ui.TextStyle(
                    color: AppCoverPalette.ink,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                    height: 1.16,
                  ),
                )
                ..addText(chars.characters.join('\n')))
              .build()
            ..layout(ui.ParagraphConstraints(width: w - pad * 3));
      canvas.drawParagraph(
        titlePara,
        Offset(pad * 1.5, (h - titlePara.height) / 2),
      );

      // 演播署名贴底 + 短横线
      final trimmedAuthor = author?.trim();
      if (trimmedAuthor != null && trimmedAuthor.isNotEmpty) {
        final authorSize = (w * 0.085).clamp(9.0, 13.0).toDouble();
        final authorPara = (ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textAlign: TextAlign.center,
                fontSize: authorSize,
                maxLines: 1,
                ellipsis: '…',
                fontWeight: FontWeight.w400,
              ),
            )
                  ..pushStyle(
                    ui.TextStyle(
                      // 0.95 而非更低：赭石底上 0.82 只有 3.98:1，不达 AA
                      color: AppCoverPalette.ink.withValues(alpha: 0.95),
                      fontSize: authorSize,
                      fontWeight: FontWeight.w400,
                    ),
                  )
                  ..addText(trimmedAuthor))
                .build()
              ..layout(ui.ParagraphConstraints(width: w - pad * 0.8));
        final authorY = h - h * 0.075 - authorPara.height;
        canvas.drawParagraph(authorPara, Offset(pad * 0.4, authorY));
        canvas.drawRect(
          Rect.fromLTWH(
            (w - w * 0.16) / 2,
            authorY - h * 0.028 - 1,
            w * 0.16,
            1,
          ),
          Paint()..color = AppCoverPalette.rule,
        );
      }

      picture = recorder.endRecording();
      image = await picture.toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    } finally {
      picture?.dispose();
      image?.dispose();
    }
  }
}
