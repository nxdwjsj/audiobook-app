import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/models/chapter.dart';

void main() {
  group('Chapter', () {
    test('fromJson parses metadata correctly', () {
      final json = {
        'name': 'book_ch01.mp3',
        'title': 'Chapter 1: Introduction',
        'length': '125.5',
        'format': 'VBR MP3',
      };

      final chapter = Chapter.fromJson(json);
      expect(chapter.filename, 'book_ch01.mp3');
      expect(chapter.title, 'Chapter 1: Introduction');
      expect(chapter.duration, const Duration(seconds: 125));
      expect(chapter.format, 'VBR MP3');
    });

    test('fromJson derives title from filename when title is absent', () {
      final json = {
        'name': 'my_book_chapter_01.mp3',
        'length': '60',
      };

      final chapter = Chapter.fromJson(json);
      expect(chapter.title, 'my book chapter 01');
    });
  });
}
