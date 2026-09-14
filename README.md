# 开发交接文档（听书 App）

> 本文档用于**新会话继续开发**。读完这篇即可上手，无需翻历史对话。
> 项目路径：`D:\Project\TraeWorkspace\audiobook\audiobook_app_src`

---

## 1. 项目是什么

一个 Flutter 有声书播放器（主用 Android 真机），核心能力是**直接播放网盘里的音频文件夹**，把网盘文件夹当作一本书来管理（目录、进度、续播、历史）。

- 应用名：`audiobook_app`，显示名「听书」
- 版本：`1.0.0+1`
- 平台目录：`android/`（主力）、`ios/`、`web/`（未验证）

**技术栈**

| 用途 | 依赖 |
|---|---|
| 播放 | `just_audio` |
| 网络 | `dio` |
| 本地存储 | `hive` / `hive_flutter` / `path_provider` |
| 状态管理 | `provider` |
| 选文件 | `file_picker` |
| 其他 | `cached_network_image`、`url_launcher`、`crypto`、`encrypt`、`html`、`intl` |
| 代码生成 | `build_runner` + `hive_generator` |

**开发环境（本机实测）**：Flutter `3.47.2` stable / Dart `3.13.2`（Windows）。

---

## 2. 环境准备与常用命令

```powershell
cd D:\Project\TraeWorkspace\audiobook\audiobook_app_src

flutter pub get
flutter analyze                                        # 当前应为 0 error
flutter test                                           # test/models_test.dart
dart run build_runner build --delete-conflicting-outputs   # 改动 Hive 模型后必须执行
flutter build apk --debug                              # 产出 build\app\outputs\flutter-apk\app-debug.apk
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

**抓真机日志（推荐方式）**

```powershell
adb logcat -c                                            # 先清空
# 手机上操作 App ...
adb logcat -d -s flutter:V | Select-String -Pattern 'Player|StorageService'
```

> 这台手机上 `flutter run` 会话容易被系统打断（MIUI 切后台、微信小程序抢前台），
> 所以**改完代码优先用 `build apk + adb install -r` 覆盖安装**，比 `flutter run` 稳。

---

## 3. 代码结构

```
audiobook_app_src/
├─ lib/
│  ├─ main.dart                 # 入口：初始化存储 → 创建网盘服务 → Provider 注入
│  ├─ models/                   # 数据模型（Hive 模型 + .g.dart 生成文件）
│  ├─ repositories/             # 本地数据仓储（书架/进度/历史/统计），均为 ChangeNotifier
│  ├─ services/                 # 业务服务（播放器、网盘、本地导入、存储）
│  ├─ pages/                    # 页面
│  ├─ widgets/                  # 通用组件（迷你播放栏、导航节流等）
│  └─ theme/app_theme.dart      # 亮/暗色主题
├─ test/                        # 单元测试
├─ tool/                        # 独立调试脚本（纯 Dart，不参与打包）
└─ android/ ios/ web/           # 平台工程
```

### 关键文件

| 文件 | 职责 |
|---|---|
| [main.dart](audiobook_app_src/lib/main.dart) | 依赖注入总入口；网盘服务的 `streamUrlResolver` 在这里装配 |
| [audio_player_service.dart](audiobook_app_src/lib/services/audio_player_service.dart) | **播放核心**：加载章节、解析直链、会话制历史、预加载、定时关闭 |
| [cloud_drive_service.dart](audiobook_app_src/lib/services/cloud_drive_service.dart) | 网盘抽象接口 + `ResolvedStream` / `ShareParseResult` |
| [quark_drive_service.dart](audiobook_app_src/lib/services/quark_drive_service.dart) | 夸克网盘实现（Cookie 登录，含校验后落盘） |
| [quark_web_login_page.dart](audiobook_app_src/lib/pages/quark_web_login_page.dart) | 夸克登录：内置 WebView 打开官方登录页，自动读取 Cookie |
| [baidu_drive_service.dart](audiobook_app_src/lib/services/baidu_drive_service.dart) | 百度网盘实现（OAuth + access_token） |
| [storage_service.dart](audiobook_app_src/lib/services/storage_service.dart) | Hive 初始化、box 与 adapter 注册 |
| [shelf_book_detail_page.dart](audiobook_app_src/lib/pages/shelf_book_detail_page.dart) | 书籍详情页：封面/信息/完整目录/目录工具条 |
| [player_page.dart](audiobook_app_src/lib/pages/player_page.dart) | 播放页（全局唯一，见 `pushPlayerPage`） |
| [home_page.dart](audiobook_app_src/lib/pages/home_page.dart) | 底部三 tab（书架/历史/统计）+ 手势返回联动 |
| [stats_page.dart](audiobook_app_src/lib/pages/stats_page.dart) | 收听统计：月度方格热力图 + 总时长 + 单本时长 |
| [throttled_navigator.dart](audiobook_app_src/lib/widgets/throttled_navigator.dart) | 跳转节流（600ms）+ 播放页单例守卫 |
| [tool/quark_crawler.dart](audiobook_app_src/tool/quark_crawler.dart) | **夸克有声书爬虫（原型，未接入 App）**：B 站搜索发现分享 → 解析目录 → 统计音频 |

### 夸克有声书爬虫（原型）

独立 Dart 脚本，用来评估「自动发现网盘有声书」是否值得做进 App。复用 App 内同一套
`sharepage/token` + `sharepage/detail` 接口，只读、可传 Cookie。

```bash
cd audiobook_app_src
dart run tool/quark_crawler.dart --keyword 有声小说 --limit 8          # 搜索发现并解析
dart run tool/quark_crawler.dart --links https://pan.quark.cn/s/xxx    # 只解析指定分享
dart run tool/quark_crawler.dart --keyword 三体 --out out.json          # 导出完整 JSON
```

| 环节 | 现状 |
|---|---|
| 解析分享（token → 递归列目录 → 过滤音频） | ✅ 稳定可用 |
| 发现：B 站搜索接口 | ✅ 可用（缺 `buvid3` 会 412，脚本会取 Cookie 并本地兜底） |
| 发现：Bing/360/Sogou 结果页 | ❌ 实测基本被反爬拦掉，需 `--engine` 才启用 |
| 非法/失效分享 | ✅ 正确报错（`41006` 分享不存在、`41010` 违规内容） |

已知限制：搜索接口的 `description` 常被平台截断，所以简介没贴链接的视频会漏掉；
命中率强依赖关键词（`<书名> 夸克` 效果最好）。

---

## 4. 架构与数据流

### 4.1 Provider 注入（`main.dart`）

启动顺序：`StorageService.init()` → `BaiduDriveService/QuarkDriveService.init()` → `runApp(MultiProvider(...))`。

注入项：

- `BookshelfRepository`、`ProgressRepository`、`ListenSessionRepository` → **ChangeNotifierProvider**（会通知 UI 刷新）
- `BaiduDriveService`、`QuarkDriveService`、`AudioPlayerService` → ChangeNotifierProvider
- `BookmarkRepository`、`LocalImportService` → 普通 Provider

> ️ 新增需要驱动 UI 刷新的仓储时，必须用 `ChangeNotifierProvider`，并在写操作后 `notifyListeners()`，
> 页面用 `context.watch<X>()`。历史上踩过坑：仓储是普通类时 UI 不刷新，看起来像"操作无效"。

### 4.2 播放链路

```
书架/详情页/历史 点播
        ↓
AudioPlayerService.playBook() 或 jumpToChapter()   ← 手动点播：新建一条收听会话
        ↓
_loadCurrentChapter()
        ↓ 章节 fileId 需要解析？
        ├─ 命中预加载缓存 _resolvedCache → 直接用
        ─ 否则 streamUrlResolver(chapter) → 按 driveType 路由到夸克/百度服务
        ↓
_player.setUrl(url, headers: resolved.headers)
        ↓
自动连播（completed）→ nextChapter()  ← 只更新当前会话，不新建
```

`streamUrlResolver` 在 [main.dart](audiobook_app_src/lib/main.dart) 中定义：

- 按 `chapter.driveType` 严格路由（夸克分享链接**不能**交给百度服务）
- 分享来源走 `getShareAudioStreamUrl(shareUrl, fileId)`，自有网盘走 `getAudioStreamUrl(fileId)`

### 4.3 本地存储（Hive）

box：`bookshelf` / `playback_progress` / `app_config` / `listen_sessions` / `listening_stats`

已用 `typeId`（**新增模型请用未占用的号，并重新跑 build_runner**）：

| 模型 | typeId |
|---|---|
| `PlaybackProgress` | 1 |
| `BookshelfBook` | 2 |
| `ListenSession` | 3 |

> `typeId 0`（原 `Bookmark`）随书签功能移除已空出，可复用。
> `listening_stats` 存纯 Map（按天/按书时长），不需要 typeId 与 build_runner。

`app_config` 存网盘登录态：夸克 Cookie（`saveQuarkCookie`）、百度 AppKey/access_token。

### 4.4 网盘接入要点

- **夸克登录**：优先用内置 WebView 打开夸克官方登录页（手机号 + 验证码），
  登录后读 WebView 的 Cookie 交给 `setCookie` 校验、通过才落盘，不用手动抓包；
  手动粘贴 Cookie 作为备用入口保留。
  **CDN 强制要求 Cookie，否则返回 412**；UA/Referer 无效。
  请求头仅 `{'Cookie': cookie}`。日志**绝不能**打印 headers/Cookie（曾泄露到 logcat，已修）。
- **百度**：OAuth（AppKey + 手动粘贴 access_token）；`dlink` 必须拼 `access_token` 且带浏览器 UA。

> `flutter_inappwebview` **必须锁 6.2.0-beta.3**：稳定版 6.1.5 依赖的
> `flutter_inappwebview_android` 1.1.3 仍调用 `getDefaultProguardFile('proguard-android.txt')`，
> 本项目用的 AGP 9.1.0 已不支持，会直接构建失败；beta 线的 1.2.0-beta.3 才改成
> `proguard-android-optimize.txt`。

---

## 5. 已完成的功能

- **书架**：本地音频导入、网盘文件夹导入（递归收集子文件夹音频，最多 5 层，自然序排列）、
  长按移出书架 / 打开网盘文件夹、拖动排序、点击进入详情页
- **书籍详情页**：封面（无封面时按书名哈希生成渐变占位图）、作者/简介、统计行、
  完整目录（懒加载，几千章不卡）、正在播放章节高亮、目录工具条（回顶部 / 定位正在播放 / 正倒序切换）
- **播放**：倍速（至 3.0x）、定时关闭（含自定义分钟）、上一章/下一章、自动连播、
  下一章预加载（播到 80% 预解析）、迷你播放栏、播放页全局唯一
- **历史**：**会话制**——手动点播新建一条记录，自动连播只更新当前记录；
  展示开始时间、听到第几章、已听时长、百分比；单条左滑删除、一键清空
- **书签已移除**；**搜索**保留（搜网盘 + 本地书架，入口在书架右上角）
- **收听统计**（替代书签 tab）：月度方格热力图，每格一天、颜色越深当天听得越久、空白=没听；
  可翻月查看；另有累计总时长 / 有记录天数 / 单本时长排行（带占比条）
- **封面文件生命周期**：编辑信息选图 → 复制到 App 私有目录 `app_flutter/covers/`；
  更换封面时删旧图，**移出书架时同步删除封面文件**，不留孤儿文件
- **交互**：全 App 跳转节流 600ms（防连点叠页面）、手势返回联动（非书架 tab 返回先回书架）、
  网盘目录逐级返回

---

## 6. 已知问题 / 待办（新会话可从这里挑活）

1. **悦听吧（yuetingba.cn）在线书源已移除且不再恢复**：App 只面向网盘（夸克/百度）+ 本地导入。
   书架里若残留历史在线书（`driveType == null` 且非本地），会显示"未知来源"，点播放提示无法播放属预期，可长按移出书架。
2. **调试脚本 lint**：`tool/debug_quark_ua.dart` 有 `avoid_print` 提示（调试用，可忽略）。
3. **未被验证的能力**：iOS / Web 平台未测；百度网盘链路在真机上验证较少。
4. 可选增强：书架分组/排序规则、搜索结果封面补齐、播放失败的错误提示 UI（`lastError` 已具备，可展示）。

---

## 7. 开发约定与踩坑记录

**约定**

- 提交信息用中文，格式「动词 + 对象」，例如：新增历史会话记录、修复夸克直链 412。
- 项目文件只能放在本项目文件夹内，不得散落到工作区根目录 `D:\Project\TraeWorkspace\`。
- 改动 Hive 模型 → 跑 `build_runner` → 再 `flutter analyze`，确保零 error。

**踩过的坑（不要再犯）**

| 现象 | 原因与结论 |
|---|---|
| 操作后 UI 不刷新 | 仓储没用 `ChangeNotifierProvider` / 忘了 `notifyListeners()` |
| 夸克播放 412 | 新 CDN `dl-pc-zb.drive.quark.cn` 强制要求 Cookie，且必须按 Range 请求 |
| 日志里出现完整登录 Cookie | 调试日志打印了 headers，**禁止**；只打"方法 URL → 状态码" |
| 连点跳多个页面 | 未走 `pushThrottled` / `pushPlayerPage` |
| `flutter run` 频繁掉线 | MIUI 切后台导致连接断开，改用 `adb install -r` + `logcat` |
| 选封面后没反应、封面存不下来 | 网盘书 `bookId` 含路径（`drive_quark_a/b`），直接拼文件名会因中间目录不存在导致 `copy()` 抛异常，且异步异常被静默吞掉 → 文件名前必须清洗 `\/:*?"<>|` |
| **代码被误删无法恢复** | 项目此前**没有 git**，删除即永久丢失 → 现已建仓，务必勤提交 |

---

## 8. 新会话快速上手清单

1. `cd D:\Project\TraeWorkspace\audiobook\audiobook_app_src`
2. 读 [main.dart](audiobook_app_src/lib/main.dart) 和 [audio_player_service.dart](audiobook_app_src/lib/services/audio_player_service.dart)（理解注入与播放链路）
3. `flutter analyze` + `flutter test` 确认基线干净
4. 要改真机行为时：`flutter build apk --debug` → `adb install -r ...` → `adb logcat -d -s flutter:V` 抓日志验证
5. 完成一个可交付的改动后提交一次（中文提交信息）