import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_page_route.dart';
import '../widgets/keep_alive_page.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/throttled_navigator.dart';
import 'drive_browser_page.dart';
import 'listening_page.dart';
import 'bookshelf_page.dart';
import 'history_page.dart';
import 'stats_page.dart';
import 'resource_search_page.dart';

/// 首页骨架（有声杂志方向，设计规范 §5.5 顶部栏目导航）。
///
/// 结构自上而下：
///   刊头（wordmark + 搜索 + 网盘） → 栏目行（在听/书架/历史/统计） → 内容 → 迷你播放条
///
/// 用顶部栏目取代底部 NavigationBar 的原因：
/// - 底部让位给常驻迷你播放条 —— 听书 App 的「接着控制播放」频率
///   不低于切栏目，且拇指够底部的成本最低；
/// - 杂志的目录逻辑是横向的「栏目」，顶部栏目更贴这个隐喻；
/// - 底部少一层 64px 的导航栏，列表首屏多露出一行内容。
///
/// 四个栏目页自身不带 AppBar（各自的动作收进页内动作行），
/// 头部只有这一份，避免「页头叠页头」。
///
/// **切换方式有两种且互不打架**：点栏目行（离散跳转）与左右滑动（连续翻页）
/// 共用同一个 [PageController]，滑动时栏目行下划线由 `onPageChanged` 驱动，
/// 不需要额外同步逻辑。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  /// 栏目页的总控制器：点栏目与手势滑动都走它。
  ///
  /// 为什么要 controller 而不是 TabController：栏目行是手写的（要在规定位置画
  /// 16×2 强调色下划线），不是 TabBar；而 TabController 需要搭下方的 TabBarView。
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  static const List<String> _tabs = ['在听', '书架', '历史', '统计'];

  static const List<Widget> _pages = [
    ListeningPage(),
    BookshelfPage(),
    HistoryPage(),
    StatsPage(),
  ];

  /// 点栏目：立即更新下划线（不等动画），同时让 PageView 翻过去。
  ///
  /// 用 animateToPage 而不是 jumpToPage：四个栏目是「一本杂志里的相邻栏目」，
  /// 让用户看见自己从哪一页翻到哪一页，比瞬间替换更容易建立方位感。
  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      index,
      duration: AppMotion.durationOf(context, AppMotion.page),
      curve: AppMotion.standard,
    );
  }

  /// 手势/返回键联动：在非「在听」栏目按返回，先切回「在听」；
  /// 已在「在听」时再按一次才真正退出（回到桌面）。
  Future<bool> _onWillPop() async {
    if (_currentIndex != 0) {
      _goToTab(0);
      return false; // 拦截，不退出
    }
    // 已在首屏：移动到后台而不是直接杀进程，符合常见听书 App 习惯
    await SystemNavigator.pop();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onWillPop();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: DecoratedBox(
          // 栏目页自身背景透明，共享这一层底色
          decoration: BoxDecoration(
            gradient: AppTheme.pageGradient(Theme.of(context).brightness),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _masthead(context, isDark),
                _tabRow(context, isDark),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    // 滑动到位才更新下划线：连续翻页时不会出现「先跳到终点」的突兀感
                    onPageChanged: (i) =>
                        setState(() => _currentIndex = i),
                    // 每页套 KeepAlivePage：PageView 默认只保留相邻页，
                    // 而栏目里的数据（列表滚动位置、已加载的书）不该因为
                    // 滑去隔壁就被丢掉 —— 之前 IndexedStack 是全留着的。
                    children: [
                      for (final page in _pages) KeepAlivePage(child: page),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 常驻迷你播放条（无在播的书时自动收起）。
        // 只在首页层级可见：进入推送路由（播放页/详情页…）时
        // 整个首页被覆盖，本条随之隐藏。
        bottomNavigationBar: const MiniPlayerBar(),
      ),
    );
  }

  /// 刊头：wordmark + 搜索入口。搜索是跨栏目动作，放刊头而不是某个栏目里。
  Widget _masthead(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 6, 0),
      child: Row(
        children: [
          Text(
            '聆云',
            style: AppType.title.copyWith(
              fontWeight: FontWeight.w500,
              letterSpacing: 3,
              color: AppInk.primary(isDark),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.search_rounded, color: AppInk.secondary(isDark)),
            tooltip: '搜索',
            onPressed: () => context.pushThrottled(
              AppPageRoute(builder: (_) => const ResourceSearchPage()),
            ),
          ),
          // 网盘入口提到刊头：它是「往里加内容」的入口，跟「在里面找内容」
          // 的搜索是同一层级的动作，不该只在书架里、藏进 ⋮ 菜单。
          IconButton(
            icon: Icon(Icons.cloud_rounded, color: AppInk.secondary(isDark)),
            tooltip: '网盘',
            onPressed: () => context.pushThrottled(
              AppPageRoute(builder: (_) => const DriveBrowserPage()),
            ),
          ),
        ],
      ),
    );
  }

  /// 栏目行：等宽四格；选中 = 主墨色 + 短强调下划线，未选中 = 次级灰。
  Widget _tabRow(BuildContext context, bool isDark) {
    return Row(
      children: [
        for (var i = 0; i < _tabs.length; i++)
          Expanded(
            child: InkWell(
              onTap: () => _goToTab(i),
              child: SizedBox(
                height: 44,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _tabs[i],
                      style: AppType.body.copyWith(
                        fontWeight: _currentIndex == i
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: _currentIndex == i
                            ? AppInk.primary(isDark)
                            : AppInk.secondary(isDark),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      width: 16,
                      height: 2,
                      color: _currentIndex == i
                          ? AppInk.accent(isDark)
                          : Colors.transparent,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
