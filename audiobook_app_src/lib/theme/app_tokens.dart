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

/// 字阶令牌（设计规范 §2）。
///
/// 全应用**只有 5 级字号、2 种字重**（400 / 500）。层级靠字号与颜色对比建立，
/// 不靠加粗与描边 —— 这是「杂志感」的字面来源。
/// 页面里不要再写裸 `TextStyle(fontSize: ...)`。
class AppType {
  const AppType._();

  /// 页面主标题（「我的书架」）。
  static const TextStyle display = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0.2,
  );

  /// 书名、卡片标题。
  static const TextStyle title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.35,
    letterSpacing: 0.1,
  );

  /// 正文、章节名。
  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  /// 作者、来源、元信息。
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// 角标、标签。
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  /// 唯一允许的第二字重：用于强调标题。
  static TextStyle emphasized(TextStyle base) =>
      base.copyWith(fontWeight: FontWeight.w500);
}

/// 封面出版色板（设计规范 §1.3）。
///
/// 生成封面取这里的高饱和深色，而不是随机渐变 —— 渐变方块是「廉价感」的来源。
/// 选色由书名哈希决定，**哈希自己实现**（FNV-1a）而不用 `String.hashCode`：
/// 后者在不同 Dart 版本间不保证稳定，会导致升级 App 后同一本书换色。
class AppCoverPalette {
  const AppCoverPalette._();

  /// 印刷品质感的低饱和深色，8 色。
  static const List<Color> colors = <Color>[
    Color(0xFF1F3D33), // 墨绿
    Color(0xFF7A2E22), // 砖红
    Color(0xFF1E2A4A), // 藏蓝
    Color(0xFF8A5A2B), // 赭石
    Color(0xFF4A2B45), // 绛紫
    Color(0xFF6B4A32), // 铜褐
    Color(0xFF34513F), // 松绿
    Color(0xFF2E2E33), // 煤灰
  ];

  /// 封面上的文字色：米白（印刷纸色），比纯白更耐看。
  static const Color ink = Color(0xFFF2EDE4);

  /// 短横线 / 内框线。
  static Color get rule => ink.withValues(alpha: 0.4);
  static Color get frame => ink.withValues(alpha: 0.25);

  /// 稳定哈希：FNV-1a 32 位，对同一输入永远返回同一值。
  static int hashOf(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// 按书名取一个稳定的封面色。
  static Color colorFor(String title) {
    final key = title.trim().isEmpty ? '书' : title.trim();
    return colors[hashOf(key) % colors.length];
  }
}

/// 界面中性阶（设计规范 §1.1、§8 无障碍）。
///
/// 「杂志感」要求界面 95% 的面积由中性色占据；主色只在可交互与选中态出现。
///
/// **每一档文字色都按 WCAG AA 校验过对比度**（正文 ≥ 4.5:1，见
/// `test/design_system_test.dart` 的自动守卫）。曾经 tertiary 用的是
/// `#9E9E9E`，在纸白底上只有 **2.56:1** —— 而它大量用在 11px 的 micro 文本上，
/// 属于典型的不达标。改色板前请先跑那条守卫测试。
class AppInk {
  const AppInk._();

  static Color page(bool isDark) =>
      isDark ? const Color(0xFF141414) : const Color(0xFFFAFAF8);
  static Color surface(bool isDark) =>
      isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFFFF);

  /// 主文字：浅色 16.65:1 ／ 深色 15.74:1
  static Color primary(bool isDark) =>
      isDark ? const Color(0xFFEDEDED) : const Color(0xFF1A1A1A);

  /// 次文字：浅色 6.38:1 ／ 深色 7.04:1
  static Color secondary(bool isDark) =>
      isDark ? const Color(0xFFA0A0A0) : const Color(0xFF5C5C5C);

  /// 弱文字（角标、元信息）：浅色 4.81:1 ／ 深色 5.48:1。
  /// 三档层级 primary > secondary > tertiary 在两种模式下都保持单调。
  static Color tertiary(bool isDark) =>
      isDark ? const Color(0xFF8C8C8C) : const Color(0xFF6F6F6F);

  static Color hairline(bool isDark) =>
      isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000);

  /// 强调色：仅用于进度条与「继续收听」这类需要被注意的标签。
  ///
  /// **必须按明暗取值**：同一个 `#1F6F4A` 在浅色底上是 5.86:1（达标），
  /// 但在深色底上只有 **3.01:1**（不达标）。所以深色模式改用更亮的松绿。
  static Color accent(bool isDark) =>
      isDark ? const Color(0xFF52B584) : const Color(0xFF1F6F4A);

  /// 墨色按钮底：选中态 / 主按钮用它，而不是彩色。
  static Color solid(bool isDark) => primary(isDark);
  static Color onSolid(bool isDark) =>
      isDark ? const Color(0xFF141414) : const Color(0xFFFAFAF8);
}
