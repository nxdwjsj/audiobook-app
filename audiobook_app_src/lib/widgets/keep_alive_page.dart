import 'package:flutter/material.dart';

/// 让 [PageView] 的每一页在切走后**保留状态**（不被销毁重建）。
///
/// 首页的四个栏目原本用 `IndexedStack` 平铺，四个页面始终挂在树上，
/// 所以切回来时滚动位置、已完成的数据加载都还在。改成可左右滑动的
/// `PageView` 后，默认只有当前页与相邻页存活 —— 从「在听」滑到「统计」
/// 再滑回来，「在听」会被整个重建（重新请求数据、丢失滚动位置）。
///
/// 这个包装是单点改动：给子页套一个带 `AutomaticKeepAliveClientMixin` 的
/// 中间节点，让 PageView 的行为回到 IndexedStack 的「全都留着」，
/// 而无需去改四个栏目页自己的 State。
class KeepAlivePage extends StatefulWidget {
  const KeepAlivePage({super.key, required this.child});

  final Widget child;

  @override
  State<KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // 必须调用：mixin 靠它在 build 时登记 keep-alive 需求
    super.build(context);
    return widget.child;
  }
}
