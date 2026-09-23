import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/models/book.dart';
import 'package:audiobook_app/models/chapter.dart';
import 'package:audiobook_app/models/drive_item.dart';
import 'package:audiobook_app/repositories/progress_repository.dart';
import 'package:audiobook_app/services/audio_player_service.dart';
import 'package:audiobook_app/services/storage_service.dart';

/// 验证「网盘登录已失效」这条 UI 链路真的生效（B4 的 cloudAuthExpired）。
///
/// main.dart 里注入的 resolver 在网盘取流失败时返回 null（异常被吞掉），
/// 同时网盘服务的 authStatus 已被置为 expired；播放器通过
/// [AudioPlayerService.cloudAuthExpiredChecker] 读到该状态，把
/// 「无法获取播放链接」替换成「登录已失效，请重新连接网盘」。
///
/// 说明：bare 测试环境里 just_audio 没有平台实现，`playBook` 结尾的
/// `_player.play()` 永远不会完成。但 `lastError` 在 `_loadCurrentChapter`
/// 里、`_player.play()` **之前**就已写好，所以这里不 await playBook，
/// 改为轮询等待 `lastError` 就绪（并在断言后 dispose 收尾）。
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

  AudioPlayerService build({required bool expired}) {
    final svc = AudioPlayerService(ProgressRepository(StorageService()));
    // 取流失败：网盘服务抛错，被 main.dart 的 resolver 吞掉后返回 null
    svc.streamUrlResolver = (chapter) async => null;
    svc.cloudAuthExpiredChecker = () => expired;
    return svc;
  }

  Future<void> waitForError(AudioPlayerService svc) async {
    for (var i = 0; i < 200; i++) {
      if (svc.lastError != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('登录已失效：取流失败后 lastError 为可操作文案，且 cloudAuthExpired=true',
      () async {
    final svc = build(expired: true);
    unawaited(svc.playBook(bookWithChapter()));
    await waitForError(svc);

    expect(svc.cloudAuthExpired, isTrue);
    expect(svc.lastError, '登录已失效，请重新连接网盘');
    svc.dispose();
  });

  test('登录正常：取流失败后保持原文案，cloudAuthExpired=false', () async {
    final svc = build(expired: false);
    unawaited(svc.playBook(bookWithChapter()));
    await waitForError(svc);

    expect(svc.cloudAuthExpired, isFalse);
    expect(svc.lastError, '无法获取播放链接');
    svc.dispose();
  });
}
