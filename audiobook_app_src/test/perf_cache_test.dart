import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/stats_repository.dart';
import 'package:audiobook_app/services/drive_list_cache.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// PERF-02（统计节流）与 PERF-03（目录缓存）的回归。
void main() {
  group('DriveListCache（PERF-03）', () {
    DriveItem folder(String name) => DriveItem(
          fileId: 'fid-$name',
          name: name,
          path: '/$name',
          isDir: true,
        );
    DriveItem audio(String name) => DriveItem(
          fileId: 'fid-$name',
          name: name,
          path: '/$name',
          isDir: false,
        );

    test('缓存键区分网盘类型 / 路径 / fid', () {
      expect(
        DriveListCache.keyFor(DriveType.quark, '/a', '1'),
        isNot(DriveListCache.keyFor(DriveType.baidu, '/a', '1')),
      );
      expect(
        DriveListCache.keyFor(DriveType.quark, '/a', '1'),
        isNot(DriveListCache.keyFor(DriveType.quark, '/b', '1')),
      );
      expect(
        DriveListCache.keyFor(DriveType.quark, '/a', '1'),
        isNot(DriveListCache.keyFor(DriveType.quark, '/a', '2')),
      );
    });

    test('命中后返回等价内容，二次取用不再需要网络', () {
      final cache = DriveListCache();
      const key = 'quark|1|/有声书';
      expect(cache.get(key), isNull);
      cache.put(key, [folder('三体')]);
      final hit = cache.get(key);
      expect(hit, hasLength(1));
      expect(hit!.single.name, '三体');
    });

    test('过期条目返回 null（TTL 生效）', () async {
      final cache = DriveListCache(ttl: const Duration(milliseconds: 40));
      const key = 'k';
      cache.put(key, [audio('a.mp3')]);
      expect(cache.get(key), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cache.get(key), isNull);
    });

    test('invalidate 立即失效（下拉刷新强制刷新的基础）', () {
      final cache = DriveListCache();
      const key = 'k';
      cache.put(key, [audio('a.mp3')]);
      expect(cache.get(key), isNotNull);
      cache.invalidate(key);
      expect(cache.get(key), isNull);
    });

    test('返回副本：调用方改动不会污染缓存', () {
      final cache = DriveListCache();
      const key = 'k';
      cache.put(key, [audio('a.mp3'), audio('b.mp3')]);
      final first = cache.get(key)!;
      first.clear();
      expect(cache.get(key), hasLength(2));
    });

    test('超出上限时淘汰最久未使用条目（LRU）', () {
      final cache = DriveListCache(maxEntries: 3);
      for (var i = 0; i < 3; i++) {
        cache.put('k$i', [audio('a$i.mp3')]);
      }
      // 触摸 k0，使其成为最近使用
      expect(cache.get('k0'), isNotNull);
      // 再写入一条，应淘汰 k1（最久未用），保留 k0
      cache.put('k3', [audio('a3.mp3')]);
      expect(cache.length, 3);
      expect(cache.get('k0'), isNotNull);
      expect(cache.get('k1'), isNull);
      expect(cache.get('k3'), isNotNull);
    });

    test('clear 清空全部', () {
      final cache = DriveListCache();
      cache.put('a', [audio('x.mp3')]);
      cache.put('b', [audio('y.mp3')]);
      cache.clear();
      expect(cache.length, 0);
    });
  });

  group('StatsRepository 通知节流（PERF-02）', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('lingyun_stats_test');
      Hive.init(tmp.path);
      await Hive.openBox(StorageService.listeningStatsBox);
      StorageService.markReadyForTesting();
    });

    setUp(() async {
      await Hive.box(StorageService.listeningStatsBox).clear();
    });

    tearDownAll(() async {
      StorageService.resetReadyForTesting();
      await Hive.close();
      await tmp.delete(recursive: true);
    });

    test('连续 addSeconds 的通知被合并，且尾部仍会通知一次', () async {
      final repo = StatsRepository(
        StorageService(),
        notifyThrottle: const Duration(milliseconds: 80),
      );
      var notifications = 0;
      repo.addListener(() => notifications++);

      // 模拟播放期间每 10 秒记一次账：连记 10 次
      for (var i = 0; i < 10; i++) {
        repo.addSeconds(10, bookId: 'b1', bookTitle: '三体');
      }
      // 第一次立即通知，其余 9 次被节流合并（原来是 10 次整页重建）
      expect(notifications, 1);

      await Future<void>.delayed(const Duration(milliseconds: 160));
      // 尾部通知把最终状态刷出去，总量远小于 10
      expect(notifications, 2);
      expect(notifications, lessThan(10));

      repo.dispose();
    });

    test('账目数据不受节流影响，累加结果完整', () async {
      final repo = StatsRepository(StorageService());
      repo.addSeconds(10, bookId: 'b1', bookTitle: '三体');
      repo.addSeconds(15, bookId: 'b1', bookTitle: '三体');
      repo.addSeconds(5, bookId: 'b2', bookTitle: '活着');

      expect(repo.totalSeconds, 30);
      final stats = repo.bookStats;
      expect(stats.first.bookId, 'b1');
      expect(stats.first.seconds, 25);
      expect(stats.last.seconds, 5);

      await repo.flush();
      repo.dispose();
    });

    test('flush 成功落盘后可重新读出（节流不影响持久化）', () async {
      final repo = StatsRepository(StorageService());
      repo.addSeconds(42, bookId: 'b1', bookTitle: '三体');
      await repo.flush();

      final reloaded = StatsRepository(StorageService());
      expect(reloaded.totalSeconds, 42);
      expect(reloaded.bookStats.single.seconds, 42);
      repo.dispose();
      reloaded.dispose();
    });

    test('dispose 后尾部定时器不再触发（不会 used-after-dispose 崩溃）',
        () async {
      final repo = StatsRepository(
        StorageService(),
        notifyThrottle: const Duration(milliseconds: 50),
      );
      repo.addSeconds(10, bookId: 'b1');
      repo.dispose();
      // 等过原定尾部通知时间：若未取消定时器，这里会抛异常
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
  });
}
