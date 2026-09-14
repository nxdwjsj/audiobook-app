# 听书（audiobook_app）

Flutter 有声书播放器：把网盘（夸克 / 百度）里的音频文件夹当作一本书来管理，支持目录、进度、续播与收听历史。

- 应用源代码：`audiobook_app_src/`
- **开发交接文档（新会话先读这篇）**：[DEVELOPMENT.md](../DEVELOPMENT.md)

## 快速开始

```powershell
cd audiobook_app_src
flutter pub get
flutter analyze
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

完整的环境要求、代码结构、架构说明、已知问题与开发约定，见 [DEVELOPMENT.md](../DEVELOPMENT.md)。