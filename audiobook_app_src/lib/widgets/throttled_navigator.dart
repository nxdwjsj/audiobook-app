import 'package:flutter/material.dart';

import '../pages/player_page.dart';

/// 全局导航节流：快速连点只推入一个页面（App 逻辑，非网页行为）。
///
/// 用法：把 `Navigator.push(context, route)` 换成
/// `context.pushThrottled(route)`。
extension ThrottledNavigator on BuildContext {
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  void pushThrottled(Route<void> route,
      {Duration cooldown = const Duration(milliseconds: 600)}) {
    final now = DateTime.now();
    if (now.difference(_lastPush) < cooldown) return;
    _lastPush = now;
    Navigator.push(this, route);
  }

  /// 全局唯一播放页：已有播放页在栈顶时不重复推入。
  /// 所有入口（书架/历史/搜索/迷你栏/详情）统一走这里。
  void pushPlayerPage() {
    final now = DateTime.now();
    if (now.difference(_lastPush) < const Duration(milliseconds: 600)) return;
    if (PlayerPage.isShown) return;
    _lastPush = now;
    Navigator.push(this, MaterialPageRoute(builder: (_) => const PlayerPage()));
  }
}
