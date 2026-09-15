import 'package:flutter_test/flutter_test.dart';

import 'package:audiobook_app/services/book_source/book_source_engine.dart';
import 'package:audiobook_app/services/book_source/book_source.dart';

void main() {
  group('BookSourceEngine', () {
    test('buildQueries handles all query modes', () {
      expect(BookSourceEngine(BookSource.fromJson({'id': 'a', 'name': 'b', 'url': 'https://x'})).buildQueries('hello world'),
          ['hello world']);
      expect(BookSourceEngine(BookSource.fromJson({'id': 'a', 'name': 'b', 'url': 'https://x', 'queries': 'fullPlusQuark'}))
          .buildQueries('hello'),
          ['hello 夸克', 'hello']);
      expect(BookSourceEngine(BookSource.fromJson({'id': 'a', 'name': 'b', 'url': 'https://x', 'queries': 'tokens2'}))
          .buildQueries('a b c'),
          ['a', 'b', 'a b c']);
      expect(BookSourceEngine(BookSource.fromJson({'id': 'a', 'name': 'b', 'url': 'https://x', 'queries': 'tokens3'}))
          .buildQueries('a b c d'),
          ['a', 'b', 'c', 'a b c d']);
    });
  });
}