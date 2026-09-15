import 'dart:ui';

import 'package:flutter/material.dart';

/// 雾白毛玻璃主题 Token（浅色 / 深色）
class FrostedGlassTheme {
  /// 浅色：偏冷雾白底色（非纯白）
  static const Color _lightBackground = Color(0xFFF7F8FC);
  static const Color _lightHighlight = Colors.white;
  static const Color _lightBorder = Color(0xFFE3E5EC);
  static const Color _lightBarrier = Colors.black;

  /// 深色
  static const Color _darkBackground = Color(0xFF1C1F28);
  static const Color _darkHighlight = Colors.white;
  static const Color _darkBorder = Colors.white;
  static const Color _darkBarrier = Colors.black;

  final Color background;
  final Color highlight;
  final Color border;
  final Color barrierColor;
  final double backgroundAlpha;
  final double surfaceAlpha;
  final double highlightAlpha;
  final double borderAlpha;
  final double barrierAlpha;

  const FrostedGlassTheme._({
    required this.background,
    required this.highlight,
    required this.border,
    required this.barrierColor,
    required this.backgroundAlpha,
    required this.surfaceAlpha,
    required this.highlightAlpha,
    required this.borderAlpha,
    required this.barrierAlpha,
  });

  /// 解析当前模式的 token
  static FrostedGlassTheme resolve(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return const FrostedGlassTheme._(
        background: _darkBackground,
        highlight: _darkHighlight,
        border: _darkBorder,
        barrierColor: _darkBarrier,
        backgroundAlpha: 0.72,
        surfaceAlpha: 0.78,
        highlightAlpha: 0.06,
        borderAlpha: 0.08,
        barrierAlpha: 0.38,
      );
    }
    return const FrostedGlassTheme._(
      background: _lightBackground,
      highlight: _lightHighlight,
      border: _lightBorder,
      barrierColor: _lightBarrier,
      backgroundAlpha: 0.72,
      surfaceAlpha: 0.82,
      highlightAlpha: 0.55,
      borderAlpha: 0.9,
      barrierAlpha: 0.22,
    );
  }
}

/// 全局复用的 blur 滤镜（顶层 final，避免每次重建）
final kFrostedBlurFilter = ImageFilter.blur(
  sigmaX: 10,
  sigmaY: 10,
  tileMode: TileMode.decal,
);

/// 雾白毛玻璃容器
///
/// 结构：RepaintBoundary → ClipRRect → BackdropFilter → Container
/// - RepaintBoundary 隔离外部重建
/// - ClipRRect 统一裁剪圆角
/// - BackdropFilter 做模糊
/// - Container 设置底色 / 顶部高光 / 描边
///
/// 禁止在滚动列表 item 中使用。
class FrostedGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const FrostedGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 18,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FrostedGlassTheme.resolve(context);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: kFrostedBlurFilter,
          child: Container(
            margin: margin,
            padding: padding,
            decoration: BoxDecoration(
              color: theme.background.withValues(alpha: theme.backgroundAlpha),
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: theme.border.withValues(alpha: theme.borderAlpha),
                width: 0.5,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 伪玻璃质感容器（不模糊）
///
/// 用于滚动列表 item 等禁用 BackdropFilter 的场景：
/// 半透明底色 + 顶部高光 + 描边，视觉接近雾白玻璃但无模糊开销。
class GlassSurface extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = 18,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FrostedGlassTheme.resolve(context);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          margin: margin,
          padding: padding,
          decoration: BoxDecoration(
            color: theme.background.withValues(alpha: theme.surfaceAlpha),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: theme.border.withValues(alpha: theme.borderAlpha),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 统一雾白毛玻璃 BottomSheet 入口。
///
/// 所有 BottomSheet 一律通过此函数弹出，不再直接调用 showModalBottomSheet。
/// 自动处理：
/// - 透明背景 + elevation 0（由 FrostedGlassContainer 提供视觉）
/// - isScrollControlled + useSafeArea + clipBehavior
/// - barrierColor 按深 / 浅色模式
/// - builder 内自动套 FrostedGlassContainer（顶部圆角 24）
Future<T?> showFrostedBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
}) {
  final theme = FrostedGlassTheme.resolve(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    clipBehavior: Clip.antiAlias,
    barrierColor: theme.barrierColor.withValues(alpha: theme.barrierAlpha),
    builder: (ctx) {
      return FrostedGlassContainer(
        borderRadius: 24,
        // 面板内的 ListTile 要在最近的 Material 上画底色/水波纹。
        // 若不垫这一层，它会落到面板外的 Material 上，既被本容器的
        // DecoratedBox 底色盖住，也会触发 debug 断言（红框糊住面板）。
        child: Material(
          type: MaterialType.transparency,
          child: builder(ctx),
        ),
      );
    },
  );
}
