# 开发交接文档（聆云 · 听书 App）

> 本文档用于**新会话继续开发**。读完这篇即可上手，无需翻历史对话。
> 项目路径：`D:\Project\TraeWorkspace\audiobook\audiobook_app_src`

---

## 1. 项目是什么

一个 Flutter 有声书播放器（主用 Android 真机），核心能力是**直接播放网盘里的音频文件夹**，把网盘文件夹当作一本书来管理（目录、进度、续播、历史）。

- 应用名：`audiobook_app`，显示名「聆云」
- 版本：`1.0.6+7`
- 平台目录：`android/`（主力）、`ios/`、`web/`（未验证）
- **下载安装**：[Releases · 最新版](https://github.com/nxdwjsj/audiobook-app/releases/latest) → 点 `lingyun-v1.0.6.apk` 直接下载安装（release 构建、debug 签名、通用包；约 56MB）
- 仓库内另有副本：`releases/lingyun-v1.0.6.apk`

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
| [quark_web_login_page.dart](audiobook_app_src/lib/pages/quark_web_login_page.dart) | 夸克登录：内置 WebView（桌面 UA）打开官方登录页，用户点按钮读取 Cookie |
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
dart run tool/quark_crawler.dart --pages https://xxx/list.html           # 直抓任意页面里的夸克链接
```

| 环节 | 现状 |
|---|---|
| 解析分享（token → 递归列目录 → 过滤音频） | ✅ 稳定可用；目录遍历为 4 并发工作池，大分享不再串行慢爬 |
| 音频识别 | ✅ 扩展名 / `obj_category` / `format_type` 三者任一命中即算音频 |
| 关键词相关性 | ✅ 解析后按标题+文件名打分，报告分「命中关键词」与「无关」两组 |
| 发现：B 站搜索接口 | ✅ 可用（缺 `buvid3` 会 412，脚本会取 Cookie 并本地兜底） |
| 发现：第一故事 yigushi.com 站内搜索 | ✅ 可用且命中率高（Destoon CMS，`/<模块>/search.php?kw=`；文章页正文直接贴夸克链接；按 token 分词搜「有声小说/评书/戏曲/儿童」四板块） |
| 发现：Mp3故事网 mp3.yangzhiyi.com 站内搜索 | ✅ 可用（Z-Blog CMS，POST `/zb_system/cmd.php?act=search`；该站搜索会匹配简介，故只认标题命中的条目） |
| 发现：slowread.net 有声书合集页 | ✅ 可用（静态大列表，`<span>标题</span>` 紧跟夸克链接，成对抽取、无需搜索与文章页） |
| 发现：放空一夏 fangkong.cc 站内搜索 | ✅ 可用（广播剧/有声书全文检索，`/s/<关键词>.html` 搜索页 HTML 直接带夸克链接；另有 `-1-9` 等分类路由） |
| 发现：`--pages` 任意页面直抓 | ✅ 可用（不做关键词过滤，页面由调用者挑；实测单页可抽 690 条链接，适合临时接入新聚合站） |
| 发现：Bing/360/Sogou 结果页 | ❌ 实测基本被反爬拦掉，需 `--engine` 才启用 |
| 非法/失效分享 | ✅ 正确报错（`41006` 分享不存在、`41010` 违规内容、`41031` 分享者被封禁） |

解析顺序：策展类渠道（fangkong / yigushi / slowread / yangzhiyi / `--pages`）的链接优先于
B 站简介链接解析，避免 `--limit` 把高精度结果截掉（实测「神秘复苏」6/6 全命中）。

已知限制：搜索接口的 `description` 常被平台截断，所以简介没贴链接的视频会漏掉；
命中率强依赖关键词（`<书名> 夸克` 效果最好）。B 站渠道对「书名+平台名」（如
`龙族 喜马拉雅`）常只返回 APK/下载工具类分享，这种情况由 yigushi 站内搜索兜底
（实测能直接命中《龙族》699 集全的文章页）；若两渠道都无结果，报告会明确显示
「命中关键词 0 个」，不会拿无关资源冒充。JSON 里的 `otherSample` 字段可看到
非音频文件名抽样，便于判断是「分享里没音频」还是「识别不出音频」。

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
书架/详情页/历史 点播（历史/进度会带 startChapter + startPosition）
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
_seekToStart()   ← 有续播位置就定位；否则套用「跳过片头」设置
        ↓
播放中 positionStream → _maybeSkipOutro()  ← 距结尾不足设定秒数 → nextChapter()
        ↓
自动连播（completed）→ nextChapter()  ← 只更新当前会话，不新建
```

`streamUrlResolver` 在 [main.dart](audiobook_app_src/lib/main.dart) 中定义：

- 按 `chapter.driveType` 严格路由（夸克分享链接**不能**交给百度服务）
- 分享来源走 `getShareAudioStreamUrl(shareUrl, fileId, filename)`（夸克会先自动转存），
  自有网盘走 `getAudioStreamUrl(fileId)`

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

- **夸克登录**：优先用内置 WebView（**桌面 UA**，否则跳「立即下载」推广页）打开夸克官方登录页
  （手机号 + 验证码），登录完成后由用户点按钮读取 WebView 的 Cookie，
  交给 `setCookie` 校验、通过才落盘，不用手动抓包；手动粘贴 Cookie 作为备用入口保留。
  **不要自动读 Cookie 并关页面**——`account/login` 未登录也会跳首页，会误判成「已完成」。
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
  长按移出书架 / 打开网盘文件夹、拖动排序、点击进入详情页、
  **封面右下角播放按钮**（网格）/ 标题行小播放钮（列表）——点击直接续播，不进详情页
  （无进度从头播、正在播该书则跳播放页）
- **书籍详情页**：封面（无封面时按书名哈希生成渐变占位图）、作者/简介、统计行、
  完整目录（懒加载，几千章不卡；**分页显示**，每页 300 集可切页，当前播放页带 ⏵ 标记）、
  正在播放章节高亮、**目录聚合浮动小圆钮**（单击展开竖排菜单：回顶部 / 定位播放 / 正倒序，
  可拖动换位并记忆；独立组件，拖动不重建列表）；
  **定位采用 `GlobalKey + Scrollable.ensureVisible` 按行精确定位**（不估算行高，长书也准）
- **悬浮播放球**（替代底部迷你播放栏）：全局挂载于 `MaterialApp.builder` 的 Overlay，
  拖动可换左右贴边、上下调整高度并记忆位置；点击展开迷你面板
  （封面/标题/章节名/上一章/播放/下一章/进播放页），面板与球同侧对齐、球太低时自动翻上方，
  展开时盖半透明遮罩；播放页打开时自动隐藏（`PlayerPage.isShown`）
- **播放**：倍速（至 3.0x）、定时关闭（含自定义分钟）、上一章/下一章、自动连播、
  下一章预加载（播到 80% 预解析）、**播放页目录面板**（打开即定位当前章节、每页 300 集分页）、
  播放页全局唯一、
  **跳过片头/片尾**（播放页右上角设置秒数，**每本书独立配置**，存 `app_config` 的
  `skip_intro_<bookId>` / `skip_outro_<bookId>`；章节本身过短时不跳，避免连跳整本书）
- **通知栏 / 锁屏播放控制**：`just_audio_background`——音频源带 `MediaItem` tag
  （书名 / 章节名 / 封面），通知栏显示当前章节与播放进度，支持播放暂停、拖动进度、
  切上一/下一章（单源模式下切章按钮由 App 内控制）；后台播放靠前台服务维持，
  `MainActivity` 必须继承 `AudioServiceActivity`，Android 13+ 需 `POST_NOTIFICATIONS` 运行时授权
- **历史**：**会话制**——手动点播新建一条记录，自动连播只更新当前记录；
  展示开始时间、听到第几章、已听时长、百分比；单条左滑删除、一键清空；
  点击记录从**记录的章节 + 位置**续播（不是从该章开头）
- **搜索**：书架内搜索（网盘+本地）；**全网搜书**（书架右上角「⋮」→ 全网搜书）——
  复用爬虫的 5 路发现渠道（B 站 / yigushi / yangzhiyi / slowread / fangkong）发现夸克分享，
  递归解析出音频数与体积，按关键词打分排序，边解析边出结果（首个结果几秒可见），
  可一键加入书架或直接播放（`ResourceSearchService` + `QuarkDriveService.parseShareGroups`）
  - **按书拆分**：一个分享 = 一个合集时，顶层每个目录各算一本（`ShareGroup`），
    结果列表里分别成条，不再把几十本混成一本书（单分享最多列 20 本）
  - **只转存选中那本**：转存时只提交该书的顶层条目（`entries`），不会把整个合集搬进网盘
  - **保存位置可选**：搜索页顶部「保存到：xxx」可浏览网盘自选目录，选择被记住，
    默认用夸克的「来自：分享」；保存后书籍会记录**网盘存放路径**
    （`drivePath` + 顶层目录 `driveDirFid`），书架长按即可「打开网盘文件夹」直达，
    顶层是散文件时退到父目录
- **书架布局**：「⋮」→ 书架布局，可选 3 列（默认）/ 2 列 / 4 列 / 列表视图，
  列表视图为封面在左的横向卡片，选择持久化
- **分享书播放必须转存**：夸克分享文件**没有直链**（`share/sharepage/download` 返回 404），
  必须用 `share/sharepage/save` 转存到自己网盘（异步任务 + 轮询 `task`，目标目录优先
  「来自：分享」）后，用转存得到的新 fid 走 `file/download` 播放。
  搜书页点「加入书架/播放」会自动转存（章节 fid 直接存网盘 fid，播放秒开）；
  历史遗留的分享书（章节存的是分享内 fid）在首次播放时懒转存，并按文件名回配 fid
  （`QuarkDriveService.saveShareToMyDrive` / `getShareAudioStreamUrl`）
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
| 播放页卡顿 | `positionStream` 每次位置更新都 `notifyListeners()`，而播放页/迷你栏都 `context.watch`，导致整页（含封面图）高频重建 → 通知按**整秒节流**（进度显示精度只需到秒） |
| 开片尾跳过后瞬间连跳好几章 | `_maybeSkipOutro` 里切章是异步的，期间位置事件仍停在旧章节末尾；而 `_loadCurrentChapter` 又把去重标记清空，于是连锁触发 `nextChapter()` → 改用 `_switchingChapter` 锁，**加载章节时不清、落到新章节（位置距结尾还早）时才解除** |
| **代码被误删无法恢复** | 项目此前**没有 git**，删除即永久丢失 → 现已建仓，务必勤提交 |
| **release 包装上后整个 App 断网**（WebView 白屏、Cookie 校验必失败） | Flutter 只在 `android/app/src/debug/AndroidManifest.xml` 里加了 `INTERNET` 权限，`main/AndroidManifest.xml` **没有** → debug 版正常、release 版无网络权限。**已修**：main 清单显式声明 `INTERNET`，发布前务必核对 |
| 通知栏不显示播放卡片 | 三个条件缺一不可：main 清单注册 `com.ryanheise.audioservice.AudioService` + `MediaButtonReceiver`、`MainActivity` 继承 `AudioServiceActivity`、Android 13+ 授予 `POST_NOTIFICATIONS`。权限改在**开始播放时**用 `permission_handler` 申请（早期放在 `MainActivity.onCreate` 里，部分 ROM 弹不出来）；被拒时播放页会提示并可一键跳系统设置 |
| 夸克登录页显示成「立即下载」推广页 | `pan.quark.cn/account/login` 在手机 UA 下会重定向到下载引导页 → 内置 WebView 必须伪装桌面 UA 并开 `useWideViewPort` |
| 点一本书却把整个合集转存进网盘 | 分享顶层是多个书目录时要按顶层分组（`ShareGroup`），转存只提交该组的 `entries`，bookId 也要带书名（否则同一分享多本书 id 冲突） |
| 页面整块变成灰色空白 | 页面里用了 `context.read<X>()` 但 `X` 没注册成 Provider → 取不到就抛 `ProviderNotFoundException`，整页渲染失败。加新 Provider 后要同步在 `main.dart` 的 `MultiProvider` 里注册（`StorageService` 就是这样漏掉过） |
| 登录页「刚打开就自动关掉」 | 别在 `onLoadStop` 里按 URL 猜登录状态：`pan.quark.cn/account/login` 未登录也会跳到首页，一读 Cookie（WebView 可能残留旧会话）就 `pop` → 现在只做文案提示，**由用户点按钮完成** |
| 转存成功却弹「转存结果数量异常（0/1）」 | 夸克任务 done 时 `save_as_top_fids` 有时为空（转存**目录**尤其常见）→ 先复查两轮 task，仍为空就列目标目录按名字 + 类型回查新 fid |
| 目录定位不准（定位到半截/错行） | 按「行高 64px × index」估算偏移在 dense + 单双行混排时不准 → 改 `GlobalKey` 标记行 + `Scrollable.ensureVisible` 精确定位；长书先切到所在分页再等一帧定位 |
| 书架封面播放按钮点击穿透进详情页 | 内层 `GestureDetector` 默认 `deferToChild`，tap 被外层 `InkWell` 赢走 → 设 `behavior: HitTestBehavior.opaque` 让内层赢得手势竞技场 |
| 悬浮面板展开只露出一条/出屏 | 面板沿用球的贴边 `left` 定位，球在右侧时面板向右伸出屏幕 → 面板单独定位：与球同侧对齐、宽度夹在屏内，球太低时翻到球上方 |
| 浮动按钮拖动卡顿 | 拖动的 `setState` 落在页面级 State 上，每帧重建整页（含 300 行目录）→ 抽成独立 `StatefulWidget`，拖动只重绘自身 |

---

## 8. 新会话快速上手清单

1. `cd D:\Project\TraeWorkspace\audiobook\audiobook_app_src`
2. 读 [main.dart](audiobook_app_src/lib/main.dart) 和 [audio_player_service.dart](audiobook_app_src/lib/services/audio_player_service.dart)（理解注入与播放链路）
3. `flutter analyze` + `flutter test` 确认基线干净
4. 要改真机行为时：`flutter build apk --debug` → `adb install -r ...` → `adb logcat -d -s flutter:V` 抓日志验证
5. 完成一个可交付的改动后提交一次（中文提交信息）