import 'package:flutter_test/flutter_test.dart';

import 'package:audiobook_app/services/book_source/book_source.dart';
import 'package:audiobook_app/services/book_source/book_source_engine.dart';

void main() {
  group('BookSource', () {
    test('fromJson parses minimal required fields', () {
      const json = {
        'id': 'test',
        'name': 'Test Source',
        'url': 'https://example.com/search?q={{key}}',
      };
      final source = BookSource.fromJson(json);
      expect(source.id, 'test');
      expect(source.name, 'Test Source');
      expect(source.urlTemplate, 'https://example.com/search?q={{key}}');
      expect(source.rank, 1); // default
      expect(source.method, 'GET'); // default
    });

    test('fromJson validates required fields', () {
      expect(() => BookSource.fromJson(const {}), throwsFormatException);
      expect(() => BookSource.fromJson(const {'name': 'Test'}), throwsFormatException);
      expect(() => BookSource.fromJson(const {'id': 'test'}), throwsFormatException);
      expect(() => BookSource.fromJson(const {'id': 'test', 'name': 'Test'}), throwsFormatException);
    });

    test('fromJson validates URL format', () {
      const json = {
        'id': 'test',
        'name': 'Test',
        'url': 'invalid-url',
      };
      expect(() => BookSource.fromJson(json), throwsFormatException);
    });

    test('fromJson validates regex patterns', () {
      const json = {
        'id': 'test',
        'name': 'Test',
        'url': 'https://example.com',
        'sharePattern': '[invalid-regex',
      };
      expect(() => BookSource.fromJson(json), throwsFormatException);
    });

    test('toJson round-trip preserves data', () {
      const json = {
        'id': 'test',
        'name': 'Test Source',
        'url': 'https://example.com/search?q={{key}}',
        'rank': 0,
        'method': 'POST',
        'headers': {'Authorization': 'Bearer token'},
        'body': {'q': '{{key}}'},
        'listLinkPattern': r'<a href="([^"]+)">([^<]+)</a>',
        'sharePattern': r'example\.com/s/([a-z0-9]+)',
        'passcodePattern': r'code[:：]\s*([a-z0-9]{4})',
        'passcodeWindow': 300,
      };
      final source = BookSource.fromJson(json);
      expect(source.toJson(), json);
    });

    test('queries field affects buildQueries output', () {
      const json = {
        'id': 'test',
        'name': 'Test',
        'url': 'https://example.com',
      };

      final engineFull = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'full'}));
      expect(engineFull.buildQueries('hello world'), ['hello world']);

      final engineFullPlusQuark = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'fullPlusQuark'}));
      expect(engineFullPlusQuark.buildQueries('hello'), ['hello 夸克', 'hello']);

      final engineTokens2 = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'tokens2'}));
      expect(engineTokens2.buildQueries('a b c'), ['a', 'b', 'a b c']);

      final engineTokens3 = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'tokens3'}));
      expect(engineTokens3.buildQueries('a b c d'), ['a', 'b', 'c', 'a b c d']);
    });
  });

  group('BookSourceEngine queries', () {
    test('queries field affects buildQueries output', () {
      const json = {
        'id': 'test',
        'name': 'Test',
        'url': 'https://example.com',
      };

      final engineFull = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'full'}));
      expect(engineFull.buildQueries('hello world'), ['hello world']);

      final engineFullPlusQuark = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'fullPlusQuark'}));
      expect(engineFullPlusQuark.buildQueries('hello'), ['hello 夸克', 'hello']);

      final engineTokens2 = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'tokens2'}));
      expect(engineTokens2.buildQueries('a b c'), ['a', 'b', 'a b c']);

      final engineTokens3 = BookSourceEngine(BookSource.fromJson({...json, 'queries': 'tokens3'}));
      expect(engineTokens3.buildQueries('a b c d'), ['a', 'b', 'c', 'a b c d']);
    });
  });
}