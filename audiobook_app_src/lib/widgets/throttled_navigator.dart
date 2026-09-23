import 'package:flutter/material.dart';
import 'app_page_route.dart';

import '../pages/player_page.dart';

/// 全局 Navigator key：
/// MaterialApp.builder 里的悬浮球不在 Navigator 子树内（与 Navigator 是 Stack
/// 兄弟关系），球的 context 调 Navigator.of 会找不到 Navigator。
/// 所有跳转统一走这个 key 直取 NavigatorState。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

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
    appNavigatorKey.currentState?.push(route);
  }

  /// 全局唯一播放页：已有播放页在栈顶时不重复推入。
  /// 所有入口（书架/历史/搜索/悬浮球/详情）统一走这里。
  void pushPlayerPage() {
    final now = DateTime.now();
    if (now.difference(_lastPush) < const Duration(milliseconds: 600)) return;
    if (PlayerPage.isShown) return;
    _lastPush = now;
    appNavigatorKey.currentState
        ?.push(AppPageRoute(builder: (_) => const PlayerPage()));
  }
}
