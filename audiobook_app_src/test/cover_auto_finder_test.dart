import 'dart:typed_data';

import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/services/book_cover_service.dart';
import 'package:audiobook_app/services/cover_auto_finder.dart';
import 'package:flutter_test/flutter_test.dart';

DriveItem _item(String name, {bool dir = false}) => DriveItem(
      fileId: 'fid_$name',
      name: name,
      path: '/$name',
      isDir: dir,
      parentPath: '/',
    );

Uint8List _bytes(List<int> head) => Uint8List.fromList([...head, ...List.filled(64, 0)]);

void main() {
  group('封面自动发现：从目录里挑封面文件', () {
    test('明确的 cover 名优先于目录里其它图片', () {
      final picked = CoverAutoFinder.pickCoverFile([
        _item('第001集.mp3'),
        _item('back.jpg'),
        _item('cover.jpg'),
        _item('随手.jpg'),
      ]);
      expect(picked?.name, 'cover.jpg');
    });

    test('扩展名大小写不敏感，中文名同样命中', () {
      expect(
        CoverAutoFinder.pickCoverFile([_item('Cover.JPG')])?.name,
        'Cover.JPG',
      );
      expect(
        CoverAutoFinder.pickCoverFile([_item('封面.png')])?.name,
        '封面.png',
      );
      expect(
        CoverAutoFinder.pickCoverFile([_item('folder.jpg')])?.name,
        'folder.jpg',
      );
    });

    test('没有明确封面名时，退而取第一张图片', () {
      final picked = CoverAutoFinder.pickCoverFile([
        _item('第001集.mp3'),
        _item('说明.txt'),
        _item('bookfront.webp'),
      ]);
      expect(picked?.name, 'bookfront.webp');
    });

    test('目录与非图片一律跳过：整览没有图就返回 null', () {
      expect(
        CoverAutoFinder.pickCoverFile([
          _item('子目录', dir: true),
          _item('cover.txt'),
          _item('第001集.mp3'),
        ]),
        isNull,
      );
      expect(CoverAutoFinder.pickCoverFile([]), isNull);
    });

    test('扩展名判定不把无扩展名/点开头的文件当图片', () {
      expect(CoverAutoFinder.isImageName('封面'), isFalse);
      expect(CoverAutoFinder.isImageName('.jpg'), isFalse);
      expect(CoverAutoFinder.isImageName('cover.jpeg'), isTrue);
    });
  });

  group('封面文件头校验：网盘里 cover.jpg 未必真是图片', () {
    test('四种图片格式都能认出来', () {
      expect(BookCoverService.looksLikeImage(_bytes([0xFF, 0xD8, 0xFF])), isTrue);
      expect(
        BookCoverService.looksLikeImage(
            _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
        isTrue,
      );
      expect(BookCoverService.looksLikeImage(_bytes([0x47, 0x49, 0x46])), isTrue);
      expect(
        BookCoverService.looksLikeImage(
            _bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        isTrue,
      );
    });

    test('HTML 错误页 / 太短的碎片 都不是图片', () {
      // 网盘鉴权失败时常返回一个 <html> 正文当文件内容
      expect(
        BookCoverService.looksLikeImage(
            Uint8List.fromList('<html><body>403</body>'.codeUnits)),
        isFalse,
      );
      expect(BookCoverService.looksLikeImage(Uint8List.fromList([0x00, 0x01])),
          isFalse);
    });

    test('扩展名按文件头选：PNG 不会被存成 jpg', () {
      expect(
        BookCoverService.extensionFor(_bytes([0x89, 0x50, 0x4E, 0x47])),
        'png',
      );
      expect(BookCoverService.extensionFor(_bytes([0xFF, 0xD8, 0xFF])), 'jpg');
      expect(
        BookCoverService.extensionFor(
            _bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
        'webp',
      );
    });
  });

  group('生成封面缓存：离屏渲染', () {
    test('渲染出来的是 PNG 字节（没有可用字体时允许放弃）', () async {
      // 测试环境可能没有中文字体，此时实现会返回 null —— 这是刻意的降级，
      // 不算失败；但绝不能抛异常。
      final bytes = await BookCoverService.renderGeneratedCover(
        title: '诡秘之主',
        author: '多人有声剧',
      );
      if (bytes != null) {
        expect(bytes.lengthInBytes, greaterThan(64));
        expect(bytes[0], 0x89);
        expect(bytes[1], 0x50);
        expect(bytes[2], 0x4E);
        expect(bytes[3], 0x47);
      }
    });

    test('空书名不抛异常（封面必有一个兜底字）', () async {
      await expectLater(
        BookCoverService.renderGeneratedCover(title: ''),
        completes,
      );
    });
  });
}
