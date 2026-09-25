import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/models/book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/progress_repository.dart';
import 'package:audiobook_app/services/audio_player_service.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 验证手动重试入口 [AudioPlayerService.retryCurrent]：
/// 立刻重新解析直链（不等退避周期），且仍失败时**重新挂上后台退避**。
///
/// 此前 playPause() 里「失败时播放键即重试」的分支取消了退避定时器却不重排，
/// 手动重试再失败就把用户留在了死状态（要点下一次才有反应）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Book bookWithChapter() => const Book(
        id: 'drive_quark_b',
        title: '测试书',
        chapters: [
          Chapter(
            filename: 'a.mp3',
            title: '第 1 集',
            duration: Duration.zero,
            fileId: 'fid-1',
            driveType: DriveType.quark,
          ),
        ],
      );

  test('retryCurrent：立刻重新解析一次，且仍失败时回到退避重试', () async {
    var calls = 0;
    final svc = AudioPlayerService(ProgressRepository(StorageService()));
    svc.streamUrlResolver = (chapter) async {
      calls++;
      return null; // 取流失败：解析器返回 null，lastError 写入
    };
    svc.cloudAuthExpiredChecker = () => false;

    unawaited(svc.playBook(bookWithChapter()));
    for (var i = 0; i < 200 && svc.lastError == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(svc.lastError, isNotNull);
    // playBook 首次失败不会自己进退避（退避由切章 / onResume 路径启动），
    // 所以此时界面上应当直接是可以点的「重试」。
    expect(svc.retrying, isFalse,
        reason: 'playBook 首次失败只置 lastError，不进入静默退避');

    final before = calls;
    await svc.retryCurrent();

    expect(calls, before + 1, reason: '手动重试必须立刻重新解析直链，而不是等退避周期');
    expect(svc.lastError, isNotNull);
    expect(svc.retrying, isTrue,
        reason: '手动重试仍失败时要把退避重新挂上，不能让用户卡在「点了没反应」');

    svc.dispose();
  });

  test('没有当前书时 retryCurrent 是空操作（不抛异常）', () async {
    final svc = AudioPlayerService(ProgressRepository(StorageService()));
    await svc.retryCurrent();
    expect(svc.lastError, isNull);

    svc.dispose();
  });
}