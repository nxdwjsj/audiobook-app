import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/models/bookshelf_book.dart';
import 'package:audiobook_app/models/playback_progress.dart';
import 'package:audiobook_app/pages/bookshelf_page.dart';
import 'package:audiobook_app/pages/listening_page.dart';

/// 首屏（「在听」页）的两处纯逻辑回归：
/// 1. 取「最近一次收听」记录 —— 决定打开 App 第一眼看到哪本书；
/// 2. 期号编号 —— 「有声杂志」方向的签名元素，编错了会很显眼。

BookshelfBook _book(String id, {int daysAgo = 0}) => BookshelfBook(
      id: id,
      title: id,
      addedAt: DateTime(2026, 9, 24).subtract(Duration(days: daysAgo)),
    );

PlaybackProgress _p(
  String bookId, {
  int chapterIndex = 0,
  required DateTime updatedAt,
}) {
  return PlaybackProgress(
    bookId: bookId,
    chapterIndex: chapterIndex,
    positionSeconds: 0,
    updatedAt: updatedAt,
  );
}

void main() {
  final base = DateTime(2026, 9, 24, 10);

  group('最近一次收听记录的选取', () {
    test('取 updatedAt 最新的那条', () {
      final all = [
        _p('a', updatedAt: base),
        _p('b', updatedAt: base.add(const Duration(minutes: 30))),
        _p('c', updatedAt: base.add(const Duration(minutes: 5))),
      ];
      expect(latestPlaybackProgress(all)?.bookId, 'b');
    });

    test('空列表返回 null（首屏据此整卡不显示）', () {
      expect(latestPlaybackProgress([]), isNull);
    });

    test('只有一条时就是它', () {
      expect(latestPlaybackProgress([_p('a', updatedAt: base)])?.bookId, 'a');
    });

    test('不修改传入的列表顺序（避免把 UI 的状态搅乱）', () {
      final all = [
        _p('a', updatedAt: base),
        _p('b', updatedAt: base.add(const Duration(hours: 2))),
      ];
      latestPlaybackProgress(all);
      expect(all.map((e) => e.bookId).toList(), ['a', 'b']);
    });

    test('同一时间戳时不崩，且返回其中一条', () {
      final all = [
        _p('a', updatedAt: base),
        _p('b', updatedAt: base),
      ];
      final picked = latestPlaybackProgress(all);
      expect(picked, isNotNull);
      expect(['a', 'b'], contains(picked!.bookId));
    });
  });

  group('期号编号（有声杂志的签名元素）', () {
    test('按入库顺序编号，老书是 NO.01', () {
      final ordered = [_book('a'), _book('b'), _book('c')];
      expect(ListeningPage.issueNumber(ordered, 'a'), 'NO.01');
      expect(ListeningPage.issueNumber(ordered, 'c'), 'NO.03');
    });

    test('补零到两位：第 7 本是 NO.07 而不是 NO.7', () {
      final ordered = List.generate(9, (i) => _book('b$i'));
      expect(ListeningPage.issueNumber(ordered, 'b6'), 'NO.07');
    });

    test('超过 99 本不截断（两位数自然增长）', () {
      final ordered = List.generate(105, (i) => _book('b$i'));
      expect(ListeningPage.issueNumber(ordered, 'b104'), 'NO.105');
    });

    test('书不在列表里时返回空串，让调用方不画那一行', () {
      expect(ListeningPage.issueNumber([_book('a')], 'zzz'), '');
    });
  });
}
