# 聆云（audiobook_app）项目技术文档

> 项目路径：`D:\Project\TraeWorkspace\audiobook\audiobook_app_src`
> 当前版本：`1.5.0+32`（发布 APK 仅 arm64）

---

## 1. 项目技术栈

| 项 | 内容 |
|---|---|
| Flutter 版本 | `3.47.2` stable（Framework revision d3b14c8769，2026-08-26） |
| Dart 版本 | `3.13.2`（SDK 约束 `>=3.0.0 <4.0.0`，Flutter 约束 `>=3.10.0`） |
| 状态管理 | **Provider**（`provider: ^6.1.1`）+ 少量 `setState`；仓储层均为 `ChangeNotifier`，UI 用 `context.watch<X>()` / `context.read<X>()` |
| 路由 | **Navigator 1.0**（`MaterialPageRoute` 直推），全部为 `Navigator.push` + 自研 `pushThrottled` 节流封装。原先「声明了未使用」的 `go_router` 已在清理中删除 |
| 网络 | **Dio**（`dio: ^5.4.0`） |
| 本地存储 | **Hive**（`hive: ^2.2.3` + `hive_flutter: ^1.1.0` + `path_provider`）；**未用** SharedPreferences / sqflite |
| 图片加载 | **cached_network_image**（`^3.3.0`）+ 本地封面 `Image.file`（均带 `memCacheWidth` / `cacheWidth` 限制解码尺寸） |
| 音频播放 | `just_audio: ^0.9.36` + `audio_service: ^0.18.19`（通知栏/锁屏控制）。**不用** `just_audio_background`：它在 Android 16 上 MediaSession 状态无法更新，通知栏永远不出现，现由 `AudioPlayerService` 内部持 `AppAudioHandler` 手动推送状态 |
| 内置 WebView | `flutter_inappwebview: 6.2.0-beta.3`（夸克登录页，**必须锁此版本**，稳定版在 AGP 9 下构建失败） |
| 其他 | `file_picker`（本地导入）、`url_launcher`（OAuth）、`html`、`permission_handler: 11.3.1`（`encrypt` 保留未用，留给后续 Hive 加密） |
| 代码生成 | `hive_generator` + `build_runner`（Hive 模型 `.g.dart`） |
| 构建环境 | Java 17、Gradle 9.3.1、AGP 9.1.0、Kotlin 2.4（`kotlin.incremental=false`，与 Java 25 组合下增量编译有 bug） |

---

## 2. 目录结构

```
audiobook_app_src/
├─ lib/
│  ├─ main.dart                    # 依赖注入总入口：StorageService.init() → 网盘服务 init → runApp(MultiProvider)
│  ├─ models/                      # Hive 数据模型（含 .g.dart 生成文件）
│  │  ├─ bookshelf_book.dart       #   书架书籍（typeId 2）
│  │  ├─ playback_progress.dart    #   播放进度（typeId 1）
│  │  ├─ listen_session.dart       #   收听会话/历史（typeId 3）
│  │  ├─ book.dart / chapter.dart / drive_item.dart  #   纯内存模型（不落盘）
│  ├─ repositories/                # 本地数据仓储，全部 ChangeNotifier（驱动 UI 刷新）
│  │  ├─ bookshelf_repository.dart #   书架 CRUD + 拖动排序 + 章节独立 box 读写 / getAll 缓存
│  │  ├─ progress_repository.dart  #   每本书的播放进度
│  │  ├─ listen_session_repository.dart  # 收听历史（上限 200 条自动裁剪）
│  │  ├─ stats_repository.dart     #   按天/按书收听时长统计（纯 Map 落 Hive，通知节流）
│  ├─ services/                    # 业务服务（网络/播放核心，Agent 禁改区，见 §7）
│  │  ├─ audio_player_service.dart #   ★ 播放核心：章节加载、直链解析、会话制历史、预加载、定时
│  │  ├─ cloud_drive_service.dart  #   网盘抽象接口 + ResolvedStream / ShareParseResult
│  │  ├─ quark_drive_service.dart  #   夸克实现（Cookie 登录、分享解析、转存）
│  │  ├─ baidu_drive_service.dart  #   百度实现（OAuth）
│  │  ├─ resource_search_service.dart  # 全网搜书（复用 5 路发现渠道）
│  │  ├─ local_import_service.dart #   本地音频文件夹导入
│  │  ├─ storage_service.dart      #   Hive 初始化、box/adapter 注册、app_config 读写
│  │  ├─ drive_list_cache.dart     #   网盘目录列举内存缓存（TTL 60s + LRU 32）
│  │  ├─ log_service.dart          #   统一日志与崩溃回捞（release 静默、URL 脱敏、crash.log 轮转）
│  ├─ pages/                       # 12 个页面
│  │  ├─ home_page.dart            #   底部三 tab（书架/历史/统计）+ 手势返回联动
│  │  ├─ bookshelf_page.dart       #   书架（网格 2/3/4 列 + 列表视图，可拖动排序）
│  │  ├─ shelf_book_detail_page.dart  # 书籍详情页（完整目录懒加载分页 + 目录浮动工具球）
│  │  ├─ player_page.dart          #   播放页（全局唯一，含目录面板/倍速/定时 BottomSheet）
│  │  ├─ history_page.dart         #   收听历史（会话制）
│  │  ├─ stats_page.dart           #   收听统计（月度热力图）
│  │  ├─ resource_search_page.dart #   全网搜书
│  │  ├─ book_source_page.dart     #   书源管理（内置源开关 / 自定义源增删）
│  │  ├─ drive_browser_page.dart   #   网盘文件浏览器（面包屑导航、竞态守卫、目录缓存）
│  │  ├─ drive_login_page.dart     #   网盘登录入口
│  │  ├─ quark_web_login_page.dart #   夸克内置 WebView 登录（桌面 UA）
│  │  ├─ edit_book_info_page.dart  #   编辑书籍信息（封面/作者/简介）
│  ├─ widgets/                     # 公共组件
│  │  ├─ book_cover.dart           #   统一封面组件（三级降级，全应用唯一渲染入口）
│  │  ├─ mini_player_bar.dart      #   常驻迷你播放条（HomePage 底部，见 §5.7 规范）
│  │  ├─ frosted_glass.dart        #   毛玻璃容器 / 底衬（FrostedGlass、showFrostedBottomSheet）
│  │  ├─ app_page_route.dart       #   统一页面转场动画
│  │  ├─ throttled_navigator.dart  #   跳转节流 600ms + 播放页单例守卫
│  └─ theme/
│     └─ app_theme.dart            # 唯一主题定义文件
├─ test/                           # 单元测试（models / book_source / online_book_source /
│                                  #   quark_auth / bookshelf_migration / perf_cache）
├─ tool/                           # 独立调试/爬虫脚本（纯 Dart，不参与打包）
└─ android/ ios/ web/
```

---

## 3. 主题与颜色

**主题定义文件**：`lib/theme/app_theme.dart`（唯一入口，Material Design 3，`ColorScheme.fromSeed` 派生）

| 项 | 配置 |
|---|---|
| 主色（种子色） | `seedColor = Color(0xFF3A3A3A)`（**墨色**，v1.4.0 起；此前为紫罗兰 `#5B4FE9`） |
| ColorScheme 派生 | `ColorScheme.fromSeed` 只用来兜住未显式指定的槽位；**primary / secondary / tertiary / surface / outline / error 必须 `copyWith` 显式指定** —— 中性 seed（`r=g=b`）的 HCT 色相未定义，M3 会派生出青色 primary（实测 `0xFF006874`）。详见设计规范 §1.2 |
| 强调色 | `AppInk.accent`：浅色 `#1F6F4A` / 深色 `#52B584`，只用于进度、链接、成功提示；`progressIndicatorTheme` 也走它（跟随主色会是一片灰） |
| 页面背景 | 浅 `#FAFAF8` / 深 `#141414` **纯色**；紫调渐变已取消，`pageGradient` 两个色标取同值 |
| 文字颜色 | 走 `AppInk` 三档令牌（primary / secondary / tertiary），均过 WCAG AA 且有守卫测试 |
| 卡片 | elevation 1、圆角 16、**无描边**（描边在纸白底上显脏）、浅色纯白 / 深色 `surfaceContainerLow` |
| 输入框 | 圆角 16、filled、focus 态 `scheme.primary`（墨色）描边 1.6 |
| BottomSheet | 顶部圆角 24 |
| Dialog | 圆角 24、浅色白 / 深色 `surfaceContainerLow` |
| AppBar | 透明背景、标题 19 / **w500**（字重只允许 400 与 500） |
| **颜色常量定义位置** | `app_theme.dart`（seed + 派生覆盖）、`app_tokens.dart`（`AppInk` 中性阶、`AppCoverPalette` 封面色板） |

> 换主色不能只改 `seedColor` 一个值：中性 seed 会让 M3 派生出带色偏的 primary，
> 必须同步改 `copyWith` 里的显式槽位，并跑 `flutter test test/design_system_test.dart`。

---

## 4. 公共 UI 组件

**现状：项目几乎没有抽公共 UI 组件层，多数 UI 在页面文件内以私有 Widget/方法实现。**

| 类型 | 组件 | 文件路径 | 说明 |
|---|---|---|---|
| 书架 item | `_BookshelfItem`（StatefulWidget，独立 Widget） | `lib/pages/bookshelf_page.dart:294` | 网格/列表双形态，含快速播放按钮、长按菜单 |
| 统一封面 | `BookCover` | `lib/widgets/book_cover.dart` | 三级降级（自选图 → 网络图 → 出版色板生成封面），全应用唯一封面渲染入口 |
| 迷你播放条 | `MiniPlayerBar` | `lib/widgets/mini_player_bar.dart` | HomePage `bottomNavigationBar` 槽位；顶边 2px 章节进度线；无在播书时收起；仅首页层级显示（推送路由自动覆盖） |
| 导航节流 | `pushThrottled` / `pushPlayerPage` | `lib/widgets/throttled_navigator.dart` | 600ms 节流 + 播放页单例 |
| 弹窗组件 | **无公共封装**，全部就地 `showDialog` / `showModalBottomSheet` | 见 §5 | 改造弹窗时需逐处处理 |
| BottomSheet | 同上，就地实现 | 见 §5 | — |
| 加载/空状态 | `_EmptyBookshelf`（书架空态） | `bookshelf_page.dart:239`；其余页面空态/加载态为就地 `Column` + 图标文案 | 无公共 Loading/Empty 组件 |
| 目录工具球 | `_ChapterFab`（独立 StatefulWidget） | `shelf_book_detail_page.dart` | 44px 聚合圆钮 + 竖排纯图标菜单（回顶/定位/排序） |

---

## 5. 所有弹窗调用位置

全项目共 **10 处**弹窗（`showDialog` ×3，`showModalBottomSheet` ×7），无 `SimpleDialog`：

| # | 文件:行 | 类型 | 用途 | 返回值 | 表单/异步 |
|---|---|---|---|---|---|
| 1 | `pages/history_page.dart:75` | showDialog\<bool\> + AlertDialog | 确认清空全部收听历史 | `bool`（确认/取消） | 无表单；确认后异步清空 repo |
| 2 | `pages/shelf_book_detail_page.dart:487` | showDialog\<bool\> + AlertDialog | 确认移出书架（连带清进度、删封面文件） | `bool` | 无表单；确认后异步 `repo.remove()` |
| 3 | `pages/player_page.dart:504` | showDialog + AlertDialog | 自定义定时分钟数 | 无（动作内完成） | **含表单**：TextField + TextEditingController（`showDialog().then(dispose)` 释放）；确定时 `int.tryParse` 校验并 `setSleepTimer` |
| 4 | `pages/bookshelf_page.dart:42` | showModalBottomSheet\<int\> | 书架布局选择（3/2/4 列、列表） | `int`（列数，0=列表） | 无表单；选择后异步 `saveShelfColumns` 持久化 |
| 5 | `pages/bookshelf_page.dart:529` | showModalBottomSheet\<String\> | 书籍长按菜单（打开网盘文件夹 / 移出书架） | `String`（'open'/'remove'） | 无表单；remove 分支异步删书 + 清进度 + SnackBar |
| 6 | `pages/drive_browser_page.dart:171` | showModalBottomSheet\<String\> | 网盘文件夹长按菜单（打开/整夹播放/加入书架） | `String`（'open'/'play'/'shelf'） | 无表单；play/shelf 分支异步递归收集音频 |
| 7 | `pages/player_page.dart:312` | showModalBottomSheet（无泛型） | 播放速度选择（ChoiceChip 0.5~3.0x） | 无（选中即 `setSpeed` + pop） | 无表单；`DraggableScrollableSheet` 可滚动 |
| 8 | `pages/player_page.dart:360` | showModalBottomSheet | 定时关闭预设（15/30/45/60/90 分钟 + 自定义 + 取消） | 无 | 无表单；含"自定义"入口转 #3；可 `cancelSleepTimer` |
| 9 | `pages/player_page.dart:428` | showModalBottomSheet\<void\> | 跳过片头/片尾秒数设置 | 无（`await` 完成后统一保存） | **含表单**：两个 TextFormField，控制器由字段自管理（避免退场动画期释放）；`isScrollControlled` 适配键盘 |
| 10 | `pages/resource_search_page.dart:59` | showModalBottomSheet\<(String,String)\> | 搜索结果转存目录选择（`_SaveDirPicker` 内部组件） | `(fid, 绝对路径)` 二元组 | 内部异步列目录；选择后 `saveQuarkSaveDir` 持久化并 setState |

---

## 6. 主页面列表实现

### 书架（主页面）— `pages/bookshelf_page.dart`

| 项 | 说明 |
|---|---|
| 列表实现 | `ReorderableListView.builder`（排序模式，:115）/ `ListView.builder`（列表视图，:139）/ `GridView.builder` + `SliverGridDelegateWithFixedCrossAxisCount`（网格 2/3/4 列，:145）；**非** CustomScrollView |
| item 独立 Widget | **是**：`_BookshelfItem`（StatefulWidget，:294），拖动/点击只重建自身 |
| 缩略图圆角 | 统一由 `BookCover` 渲染，默认圆角 10；迷你播放条封面 42×56（3:4） |
| 分页/懒加载 | `GridView.builder`/`ListView.builder` 天然懒构建（视口外不构建）；数据量（书架几十本）无需分页 |

### 其余列表（均懒加载 builder）

| 页面 | 实现 | 分页 |
|---|---|---|
| 详情页目录 `shelf_book_detail_page.dart:295` | ListView.builder | **分页**：每页 300 章，ChoiceChip 切页 |
| 播放页目录面板 `player_page.dart:737` | ListView.builder | **分页**：每页 300 章；分页 chips 本身也是横向 ListView.builder（:714） |
| 网盘浏览 `drive_browser_page.dart:588` | ListView.builder | 按目录逐级加载（天然分页） |
| 搜索结果 `resource_search_page.dart:315,574` | ListView.builder | 边解析边出结果 |
| 历史 `history_page.dart` | ListView | 数据源 200 条上限 |

---

## 7. 业务逻辑边界（Agent 禁止修改的部分）

以下区域为业务核心，**UI/主题层改造时严禁触碰**：

**网络与网盘（`services/` 全目录）**
- `quark_drive_service.dart`：Cookie 校验落盘、`sharepage/token`、分享转存（异步任务 + task 轮询 + 按名回查 fid）、CDN 直链解析（**必须带 Cookie + Range 请求，否则 412**）
- `baidu_drive_service.dart`：OAuth + dlink 拼接
- `cloud_drive_service.dart`：抽象接口与 `ResolvedStream`/`ShareParseResult` 类型
- `resource_search_service.dart`：5 路发现渠道 + 按书分组 + 评分排序

**播放核心（`audio_player_service.dart`）**
- 章节直链解析与预加载缓存（播到 80% 预解析下一章）、`_switchingChapter` 防连跳锁、跳过片头/片尾逻辑、会话制历史（手动点播新建 / 连播只更新）、进度整秒节流 `notifyListeners`
- **`streamUrlResolver` 装配在 `main.dart`**：按 `chapter.driveType` 严格路由，夸克分享链接绝不能交给百度服务

**本地存储（`storage_service.dart` + `repositories/`）**
- Hive box：`bookshelf` / `playback_progress` / `app_config` / `listen_sessions` / `listening_stats` / `chapters`
- **`chapters` box（PERF-01）**：key = bookId，value = `List<Map>`。章节不再内嵌在书记录里，
  `BookshelfBook.toJson()` 已不输出 `chapters`；读取走 `BookshelfRepository.getChapters()`：
  内存 LRU(5) → `chapters` box → 回落旧内嵌字段。**旧字段保留不清理**，双读保证可回滚。
  编辑书籍信息（`edit_book_info_page`）刻意不传 chapters，避免重写上千条章节。
- typeId 已占用：1（PlaybackProgress）、2（BookshelfBook）、3（ListenSession）；**改模型必须跑 build_runner**
- 球心比例持久化协议（`saveBallDxRatio`/`getBallDxRatio`，含旧协议兼容）、每书跳过秒数 key（`skip_intro_<bookId>`）
- 封面文件生命周期：App 私有目录 `covers/`，移出书架同步删除

**权限与系统集成**
- `permission_handler`：`POST_NOTIFICATIONS` 在**开始播放时**申请（勿移到 onCreate）
- `MainActivity` 继承 `AudioServiceActivity`、main 清单的 `INTERNET` / AudioService / MediaButtonReceiver 声明
- WebView 登录流程：桌面 UA、**由用户点按钮读 Cookie**（勿自动读并关页）

**通用红线**
- 任何 `Future`/`Stream`/`async` 的返回值与调用链
- `pushThrottled` / `pushPlayerPage`（跳转节流 + 播放页单例），勿换裸 `Navigator.push`
- 路由传参结构（如 `DriveBrowserPage(initialDrive/initialPath/initialDirFid)`）
- 日志禁止打印 headers/Cookie
- `flutter_inappwebview` 必须锁 `6.2.0-beta.3`

---

## 8. 现有弹窗的返回值与回调说明

若把 §5 中的 Dialog 改造为 BottomSheet（或反向），**必须保留**以下逻辑：

| 弹窗 | 返回值/回调 | 改造时必须保留 |
|---|---|---|
| 清空历史确认 | `bool`，true 时执行 `repo.clearAll()` | 确认动作在 `await` 之后执行；执行前 `mounted` 检查 |
| 移出书架确认 | `bool`，true 时 `remove()` + `clearProgress()`（会连带删封面文件） | 删除后 SnackBar 提示；**不可只删书不删进度** |
| 自定义定时 | 无返回值；确定时 `int.tryParse` > 0 才 `setSleepTimer` | controller 必须 dispose（`showDialog(...).then((_) => controller.dispose())`）；解析失败不关弹窗 |
| 书架布局 | `int`；null = 用户取消（不落库） | 仅 picked 非 null 才 `saveShelfColumns` + `setState` |
| 书籍长按菜单 | `String`；switch 分支 'open'（跳 DriveBrowserPage，三参传参）/ 'remove' | 'open' 用 `pushThrottled`；'remove' 删书 + 清进度 + SnackBar |
| 网盘文件夹长按 | `String`：'open' / 'play' / 'shelf' | play/shelf 走 `_playOrShelveFolder`（递归收集音频，异步） |
| 播放速度 | 选中即 `player.setSpeed(s)` + pop | 无持久化（会话级），勿加存储 |
| 定时关闭预设 | 选中即 `setSleepTimer(d)` + pop；"自定义"先 pop 再开 #3；有定时时显示"取消定时"项 | "自定义"分支的两段式 pop→push 顺序 |
| 跳过片头/片尾 | `await` 完成后统一 `saveSkipSeconds`（每书独立，存 app_config） | 输入控制器交给 TextFormField 字段自管理（勿外部 dispose，退场动画期会崩）；`isScrollControlled: true` + `viewInsets` 适配键盘 |
| 转存目录选择 | `(fid, absPath)` 记录；空串 = 默认"来自：分享"，'/' = 根目录 | 归一化逻辑（`isDefaultInbox` / 正则去斜杠）与 `saveQuarkSaveDir` 三参持久化 + setState 三个字段 |

**共性约定**：所有 `await showDialog/showModalBottomSheet` 之后必须 `mounted`（或 `context.mounted`）检查再 `setState`/`showSnackBar`；pop 传值用 `Navigator.pop(ctx, value)`。

---

## 9. pubspec.yaml 完整依赖列表

```yaml
name: audiobook_app
description: 聆云 - 网盘有声书播放器（直接播放网盘音频文件夹，管理目录、进度与收听历史）
publish_to: 'none'
version: 1.5.0+32

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: ">=3.10.0"

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.6
  # Audio playback
  just_audio: ^0.9.36
  # Network
  dio: ^5.4.0
  # Local storage
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  path_provider: ^2.1.1
  # File picking (local import)
  file_picker: ^12.3.0
  # Image caching
  cached_network_image: ^3.3.0
  # State management
  provider: ^6.1.1
  # Launch URLs (OAuth authorization)
  url_launcher: ^6.2.5
  html: ^0.15.7
  # 保留但当前无 import：留给后续 SEC-01（app_config 用 HiveAesCipher 加密）。
  # 原先并列、已确认全库 0 引用的 go_router / intl / crypto 已删除。
  encrypt: ^5.0.3
  # 内置网页登录（必须锁 6.2.0-beta 线，稳定版在 AGP 9 下构建失败）
  flutter_inappwebview: 6.2.0-beta.3
  permission_handler: 11.3.1
  # 通知栏 / 锁屏播放控制（MediaSession）。不用 just_audio_background
  # （在 Android 16 上 MediaSession 状态不更新），改由 AudioPlayerService
  # 内部持 AppAudioHandler 手动推送状态。
  audio_service: ^0.18.19

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  hive_generator: ^2.0.1
  build_runner: ^2.4.7

flutter:
  uses-material-design: true
```

---

## 10. 性能与兼容性

| 项 | 内容 |
|---|---|
| 最低 Android 版本 | **API 24（Android 7.0）**（`minSdk = flutter.minSdkVersion` = 24） |
| 目标/编译版本 | targetSdk 36 / compileSdk 36（Android 16） |
| APK 架构 | release 仅 arm64-v8a（20.5MB）；构建命令 `flutter build apk --release --target-platform android-arm64`（勿在 gradle 加 splits，与 Flutter 插件冲突） |
| 图标 tree-shaking | 已启用（MaterialIcons 1.6MB → 11.6KB） |
| iOS / Web | 工程存在但**未验证** |
| 低端设备降级策略 | **无显式策略**。已有的隐性优化：封面解码尺寸限制（cacheWidth 300~600）、长目录分页 300 章 + 懒加载、跳转节流 600ms、拖动类组件独立 StatefulWidget 化（拖动不重建整页）、进度通知整秒节流 |
| 已知性能坑 | `positionStream` 高频通知已节流到秒；MIUI 真机 `flutter run` 易断连，验证用 `adb install -r` + `logcat` |
