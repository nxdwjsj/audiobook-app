import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/pages/player_page.dart';

/// 播放页「后退 15 秒 / 前进 30 秒」的目标位置计算。
///
/// `AudioPlayerService.seek` 不做边界钳制，越界值会直接被交给底层播放器，
/// 行为依平台而异。这两条边界（不能为负、不能超过章节时长）是新增的
/// ±秒跳转功能唯一容易出错的地方，单独锁住。
void main() {
  group('offsetPosition 相对跳转', () {
    const duration = Duration(minutes: 10);

    test('正常后退', () {
      expect(
        offsetPosition(const Duration(minutes: 1), const Duration(seconds: -15),
            duration),
        const Duration(seconds: 45),
      );
    });

    test('正常前进', () {
      expect(
        offsetPosition(const Duration(minutes: 1), const Duration(seconds: 30),
            duration),
        const Duration(seconds: 90),
      );
    });

    test('后退越界时夹到 0，不返回负数', () {
      expect(
        offsetPosition(const Duration(seconds: 5), const Duration(seconds: -15),
            duration),
        Duration.zero,
      );
    });

    test('恰好在 0 时后退仍是 0', () {
      expect(
        offsetPosition(Duration.zero, const Duration(seconds: -15), duration),
        Duration.zero,
      );
    });

    test('前进越界时夹到章节时长', () {
      expect(
        offsetPosition(const Duration(minutes: 9, seconds: 50),
            const Duration(seconds: 30), duration),
        duration,
      );
    });

    test('时长未知（null）时不夹上界，但仍不返回负数', () {
      // 时长未知是流媒体的常见状态（未拿到 metadata 之前）。
      // 此时前进只能放行，否则会把用户卡在 0。
      expect(
        offsetPosition(const Duration(minutes: 1), const Duration(seconds: 30),
            null),
        const Duration(seconds: 90),
      );
      expect(
        offsetPosition(const Duration(seconds: 5), const Duration(seconds: -15),
            null),
        Duration.zero,
      );
    });

    test('delta 为 0 时返回原位置', () {
      const p = Duration(minutes: 3, seconds: 20);
      expect(offsetPosition(p, Duration.zero, duration), p);
    });

    test('时长未知且位置恰好为 0 时后退，不越界', () {
      expect(
        offsetPosition(Duration.zero, const Duration(seconds: -15), null),
        Duration.zero,
      );
    });
  });
}
