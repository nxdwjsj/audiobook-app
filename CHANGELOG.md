# 更新日志

本项目所有值得记录的变更都会写在这里。`version` 采用 `versionName+versionCode`（见 `audiobook_app_src/pubspec.yaml`）。

## [1.1.0+20] - 2026-09-23

一次面向 Android 单平台的全面优化与重构：平台精简、统一设计令牌、缺陷修复。
**用户数据与书源配置完全兼容**，升级无需重新登录、无需重新配置。

### 新增
- 第三方书源默认开启：首次安装与版本升级后，随包内置的书源（含 netdiscovery 的分享发现源与在线听书源）自动生效；只有用户手动关闭过的源才会保持关闭。
- 「减弱动效」开关（书架 → 更多 → 减弱动效）：低端设备把全局动画时长压缩约 45%、曲线退化为线性；同时尊重系统级「减少动画」无障碍开关。
- 本地音频支持多选导入：一次选择整本书的多个音频文件，按文件名自然序生成章节，书名取公共前缀。
- 存储初始化失败兜底页：不再静默丢数据，给出明确提示与重试入口。

### 优化
- 平台精简：移除 iOS 与 Web 平台目录、资源与平台分支代码，清理 `kIsWeb` 相关无效引用；分析器不再扫描 `tool/` 调试脚本。
- 统一设计令牌：新增 `lib/theme/app_tokens.dart`（间距 / 圆角 / 动效），页面跳转统一走 `AppPageRoute`（轻微上移 + 淡入），不再零散使用 `MaterialPageRoute`。
- 网络客户端统一：新增 `services/http/network_client.dart`，夸克 / 百度 / 书源引擎三处 Dio 共用超时与状态码策略。
- 进度保存更及时：debounce 由 5s 缩到 2s，并在切后台 / 锁屏 / 进程回收前补写一次，避免被系统回收时丢失最多一个周期的进度与收听时长。
- 静态分析从 15 项降到 0 项（error 与 info 均为 0）。

### 修复
- 本地导入的音频无法播放：`Uri.parse` 处理裸路径会得到无 scheme 的 URI，导致 just_audio 加载失败，改为 `Uri.file`。
- 百度网盘 Cookie 粘贴无效仍显示已登录：现在写入前会先调用用户信息接口校验，无效则不落盘并报错。
- 移除已被百度吊销的内置 demo AppKey，未配置 AppKey 时给出明确引导，不再静默失败。
- 异步异常（网盘解析、Hive 读写、书源抓取）此前不会出现在日志里，现已统一由 Zone / PlatformDispatcher 捕获并打印堆栈。
- 修复 `BuildContext` 跨 async 使用的隐患（书源导入、书架更多菜单）。

### 兼容性说明
- 书架、播放进度、收听历史、书源开关等本地数据**格式未变**，老版本直接覆盖安装即可。
- 书源禁用列表仍是原来的 `disabled_book_sources`；新增 `known_builtin_source_ids` 仅用于记录"已默认启用过"的内置源，重复升级不会重置用户手动关闭的选择。

### 已知限制（本版未处理，属破坏性变更，须与「数据导出/导入」捆绑后再动）
- 包名仍为 `com.example.audiobook_app`，release 仍使用 **debug 签名**：更换任一者都会导致覆盖安装失败、用户卸载重装丢数据。改前必须先上线数据导出/导入。
- 未开启代码混淆与资源压缩（`minifyEnabled` / `shrinkResources`）。
- 仅构建 arm64 单架构；如需覆盖 32 位设备，需改为 `flutter build apk --release`（fat APK）或分架构出包。
- 网盘 Cookie / token 仍明文存于 Hive `app_config`（见 `docs/OPTIMIZATION_AND_ROADMAP.md` 中的加密迁移项）。

### 验证结果（2026-09-23）
- `flutter analyze`：**No issues found**（原 15 项已清零）。
- `flutter test`：**40 / 40 通过**。
- `flutter build apk --release --target-platform android-arm64`：**构建成功**，产物 `build/app/outputs/flutter-apk/app-release.apk` **21.0 MB**，sha1 `42bdce98c5dd4dfc9f8b5bf5540381f322340b87`，另存为 `releases/lingyun-v1.1.0-arm64.apk`。
