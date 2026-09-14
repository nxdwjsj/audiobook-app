package com.example.audiobook_app

import com.ryanheise.audioservice.AudioServiceActivity

// 必须继承 AudioServiceActivity（而非 FlutterActivity），
// 通知栏 / 锁屏的媒体控制才能把事件送回 Flutter 侧的 AudioPlayer。
//
// 通知权限（Android 13+）不在这里请求：改由 Dart 侧在「开始播放」时
// 用 permission_handler 申请，时机更准，也避免一启动就弹权限框。
class MainActivity : AudioServiceActivity()