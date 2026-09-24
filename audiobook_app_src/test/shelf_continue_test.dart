import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/models/playback_progress.dart';
import 'package:audiobook_app/pages/bookshelf_page.dart';

/// 「继续收听」卡的取记录逻辑回归。
///
/// 这条逻辑决定了用户打开 App 第一眼看到哪本书 —— 判错就会把人指向一本
/// 早就听完的。它也是首屏唯一的一处纯逻辑，所以单独锁住。

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
}
