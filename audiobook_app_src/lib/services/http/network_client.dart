import 'package:dio/dio.dart';

/// 统一的 Dio 实例工厂。
///
/// 之前三处网络（夸克 / 百度 / 书源引擎）各自 new Dio，超时与状态码策略
/// 互不一致（百度甚至没设 validateStatus，4xx 直接抛 DioException，导致
/// 拿不到百度返回的错误响应体）。这里统一：
/// - connectTimeout 15s / receiveTimeout 20s
/// - validateStatus 限定 200 ≤ status < 600：保留 4xx/5xx 的响应体可读，
///   同时不再放行 1xx/3xx 这类脏数据
/// - 各服务只在 [BaseOptions] 之上追加自己的默认 headers
Dio createNetworkClient({
  Map<String, String>? headers,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 20),
}) {
  return Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: headers ?? const <String, String>{},
      validateStatus: (status) => status != null && status >= 200 && status < 600,
    ),
  );
}

/// 业务侧统一的响应判定：拿到响应后统一用它判断成功，
/// 避免不同服务对 statusCode 的理解不一致。
bool isHttpSuccess(Response<dynamic>? response) {
  final code = response?.statusCode;
  return code != null && code >= 200 && code < 300;
}
