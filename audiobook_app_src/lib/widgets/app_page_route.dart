import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 全局统一的页面路由动画。
///
/// 取代零散的 [MaterialPageRoute]，保证所有跳转的时间与曲线一致：
/// 轻微上移 + 淡入，既保留 Material 的空间感，又比系统默认位移更克制、
/// 在低端机上更省事。[AppMotion] 降级时时长自动压缩为 0，表现为瞬时切换。
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog,
  }) : super(
          transitionDuration: AppMotion.page,
          reverseTransitionDuration: AppMotion.pageBack,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppMotion.emphasize,
            );
            if (!AppMotion.isVisible(AppMotion.page)) {
              return child;
            }
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.025),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );
}
