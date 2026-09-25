# 聆云 · 听书 App — 新会话上手须知

> 这个文件会被自动注入到每个新会话的上下文里。**先读 [`README.md`](README.md)（351 行交接文档）再动手**，
> 里面有架构、数据流、已完成功能、待办和一张「踩过的坑」表。改任何 UI 之前必须读
> [`docs/DESIGN-SYSTEM.md`](docs/DESIGN-SYSTEM.md)（基调：杂志感 · 封面为王）。

## 代码在哪
Flutter 工程根是 **`audiobook_app_src/`**；仓库根目录只放文档、设计稿与产包归档。
所有 flutter / dart 命令都要先 `cd audiobook_app_src`。

## 常用命令（本机实测）
```powershell
cd D:\Project\TraeWorkspace\audiobook\audiobook_app_src
flutter pub get
flutter analyze                        # 必须 0 error（当前基线：No issues found）
flutter test                           # test/ 下 20 个文件、213 个用例，当前全部通过
dart run build_runner build --delete-conflicting-outputs    # 改了 Hive 模型必须跑
flutter build apk --release --target-platform android-arm64 # 约 20.5MB；不加参数会打 56MB 全架构
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb logcat -c ; adb logcat -d -s flutter:V | Select-String -Pattern 'Player|StorageService'
```

**环境（本机实测）**：Flutter `3.47.2` / Dart `3.13.2`；`JAVA_HOME=D:\AndroidStudio\android-studio\jbr`（OpenJDK 25）；
`ANDROID_HOME=D:\AndroidSdk`（platforms 34/35/36/37，build-tools 34+36）。
⚠️ 当前 `adb devices` 为空——**没有真机连接时无法装机验证**，只能做 analyze / test / 构建。

## 发版约定
- 版本号在 `audiobook_app_src/pubspec.yaml`（`versionName+versionCode`，如 `1.6.0+33`），提交信息带上 `vX.Y.Z+NN`。
- 每次发版同步更新 `CHANGELOG.md`：按功能分节，写清「为什么这么改」，对齐现有条目风格。
- APK 对外发布走 **GitHub Releases**；`releases/` 只是历史归档副本。
- 发布只出 **arm64 单架构**包。
- ⚠️ 仍是 **debug 签名**的演示包：换正式签名会导致无法覆盖安装、卸载即丢数据，必须先有「数据导出/导入」能力才能动。

## 版本管理（重要）
- 远端 `origin` = `git@github.com:nxdwjsj/audiobook-app.git`（**SSH**，已实测可推）。
  `~/.ssh/config` 把 `github.com` 走 `ssh.github.com:443`；本地公钥已注册在账号上（`ssh -T git@github.com` 应回 `Hi nxdwjsj!`）。
- HTTPS 也配置过（`https://github.com/nxdwjsj/audiobook-app.git`），但本机到 `github.com:443` 会**间歇性被阻断**
  （`api.github.com` 通、`github.com` 超时）。两条路都会抽风，卡住就换另一条，别浪费时间：
  先 `ssh -T git@github.com` 和 `Invoke-WebRequest https://github.com` 各探一次，再决定用哪个。
- SSH 曾经解析到 `127.0.0.1`（DNS 污染）导致 `Connection closed`；现在解析到真实 IP。若又出现该报错，先查 `Resolve-DnsName ssh.github.com`。
- 提交信息用中文「动词 + 对象」，例如：新增历史会话记录、修复夸克直链 412。
- `releases/` 下的历史 APK 已从 git 历史中清除（仓库从 337MB 瘦到约 1MB），目录本身被 `.gitignore` 忽略、只留本地归档。
  **发布走 GitHub Releases**；不要再把 APK 提交进仓库。

## 硬禁忌（来自 README §7 的踩坑表，最危险的几条）
- **禁止**把完整登录 Cookie / 请求 headers 打进日志；只打「方法 + URL → 状态码」。
- 项目文件只能放在本项目文件夹内，不得散落到 `D:\Project\TraeWorkspace\` 根目录。
- 改 Hive 模型 → 必须 `build_runner` → 再 `flutter analyze`（零 error）。
- `release` 包的 `INTERNET` 权限已修在 `main/AndroidManifest.xml`，**别回退**（回退后 release 包整个断网）。
- 通知栏播放卡片依赖三件事同时成立：清单注册 `AudioService`/`MediaButtonReceiver`、
  `MainActivity` 继承 `AudioServiceActivity`、Android 13+ 授予 `POST_NOTIFICATIONS`。
- 减包体只用 `--target-platform android-arm64`，**不要**在 `build.gradle.kts` 加 `splits.abi`（与 Flutter 插件冲突）。
- 空集合必须先短路返回，不要让 `clamp(0, length - 1)` 见到空列表（会 `ArgumentError` 崩溃）。
- 新增 Provider 后必须同步注册进 `main.dart` 的 `MultiProvider`，否则整页 `ProviderNotFoundException` 变灰空白。

## 工作方式
- 中文回复；改 UI 时对照规范编号（提交信息里常引用，如「规范 §5.5」）。
- 改完代码按 `test-runner` 技能验证（analyze + test + 有真机时装机验证）再汇报，不要只说「应该没问题」。
- 每个可交付的改动提交一次（这个项目曾经没有 git，发生过代码被误删无法恢复）。