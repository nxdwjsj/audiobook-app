import 'package:flutter/material.dart';

/// 全局间距令牌。
///
/// 页面中不再手写裸数字：一律从这里取值，保证不同页面的呼吸感一致。
/// 4pt 栅格：xs=4 sm=8 md=12 lg=16 xl=20 xxl=24 xxxl=32。
class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// 页面左右边距（书架/详情/列表统一）。
  static const double page = lg;

  /// 列表项之间的间距。
  static const double listGap = sm;

  /// 卡片内边距。
  static const double card = md;
}

/// 全局圆角令牌。毛玻璃体系以 12~20 为主。
class AppRadius {
  const AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double pill = 999;
}

/// 统一动效令牌：时长 + 曲线 + 降级策略。
///
/// 三条约定：
/// 1. 所有动效从这里取 `Duration` 与 `Curve`，不在页面里凭感觉写数字；
/// 2. 低端机 / 用户开启「减弱动效」时，时长按比例压缩、曲线退化为线性，
///    保证低配设备不出现掉帧与粘手感（`lowPerformance` 由 main 按持久化配置注入）；
/// 3. 系统级「减少动画」无障碍开关（[MediaQuery.disableAnimationsOf]）优先级最高。
class AppMotion {
  AppMotion._();

  /// 是否处于降级模式。main() 启动时按用户配置注入，运行中也可热切换。
  static bool lowPerformance = false;

  /// 阈值 ≤ 该值时视为"无动画"（供页面决定要不要跑 AnimatedOpacity 之类）。
  static const Duration _zeroThreshold = Duration(milliseconds: 8);

  static const Duration _tap = Duration(milliseconds: 140);
  static const Duration _pageForward = Duration(milliseconds: 240);
  static const Duration _pageBack = Duration(milliseconds: 180);
  static const Duration _sheet = Duration(milliseconds: 320);
  static const Duration _list = Duration(milliseconds: 300);
  static const Duration _player = Duration(milliseconds: 200);

  /// 点击/状态切换反馈。
  static Duration get tap => _scale(_tap);
  /// 页面进场。
  static Duration get page => _scale(_pageForward);
  /// 页面退场（比进场略快，返回时更利落）。
  static Duration get pageBack => _scale(_pageBack);
  /// 弹窗 / BottomSheet。
  static Duration get sheet => _scale(_sheet);
  /// 列表项逐个入场。
  static Duration get list => _scale(_list);
  /// 播放器内的小位移（滑块、工具条）。
  static Duration get player => _scale(_player);

  /// 标准曲线：进出对称，用于位移与缩放。
  static Curve get standard =>
      lowPerformance ? Curves.linear : Curves.easeInOutCubic;
  /// 强调曲线：头重脚轻、快速响应，用于进场。
  static Curve get emphasize =>
      lowPerformance ? Curves.linear : Curves.easeOutCubic;
  /// 退出曲线：快速起步。
  static Curve get accelerate =>
      lowPerformance ? Curves.linear : Curves.easeInCubic;

  /// 当前是否应禁用动画（系统无障碍开关优先）。
  static bool reduceMotionOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// 综合判定：系统开关或降级模式任一命中即视为无动画，
  /// 直接返回页面时长（可能为 0）。
  static Duration durationOf(BuildContext context, Duration base) =>
      reduceMotionOf(context) ? Duration.zero : _scale(base);

  /// 当前帧动画是否实际生效（duration 过短就别跑了）。
  static bool isVisible(Duration d) => d > _zeroThreshold;

  static Duration _scale(Duration d) =>
      lowPerformance ? Duration(milliseconds: (d.inMilliseconds * 0.45).round()) : d;
}
