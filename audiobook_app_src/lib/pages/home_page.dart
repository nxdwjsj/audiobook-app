import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import 'bookshelf_page.dart';
import 'history_page.dart';
import 'stats_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  static const List<Widget> _pages = [
    BookshelfPage(),
    HistoryPage(),
    StatsPage(),
  ];

  /// 手势/返回键联动：在非书架 tab 按返回，先切回书架；
  /// 已在书架时再按一次才真正退出（回到桌面）。
  Future<bool> _onWillPop() async {
    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return false; // 拦截，不退出
    }
    // 已在书架：移动到后台而不是直接杀进程，符合常见听书 App 习惯
    await SystemNavigator.pop();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onWillPop();
      },
      child: Scaffold(
        body: DecoratedBox(
          // 主界面统一渐变底：三个 tab 页自身背景透明，共享这一层
          decoration: BoxDecoration(
            gradient: AppTheme.pageGradient(Theme.of(context).brightness),
          ),
          child: IndexedStack(
            index: _currentIndex,
            children: _pages,
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
                setState(() => _currentIndex = index);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.library_books_outlined),
                  selectedIcon: Icon(Icons.library_books_rounded),
                  label: '书架',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_rounded),
                  selectedIcon: Icon(Icons.history_rounded),
                  label: '历史',
                ),
                NavigationDestination(
                  icon: Icon(Icons.insights_outlined),
                  selectedIcon: Icon(Icons.insights_rounded),
                  label: '统计',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
