// 测试夸克 CDN 对不同 User-Agent 的响应（定位 412）。
// 用法: dart run tool/debug_quark_ua.dart
import 'dart:io';

import 'package:dio/dio.dart';

const _cookie =
    '__pus=dfa040a957b1432dc68b42961b2bd230AAQgft4jcOvfXDHzlLmqu0vKPnbG2K17tZMlRVdyy7bAXVNbefpEJ6rrwGsFlgGImV4a/IA1Q1foMUWblcg/n1Zy; __uid=AARB2dRjkGUgi2ce8N015wi2; __puus=329eec301d33585e770911e8ac5a827dAAQY611Kpr5XL8Kza1YQgyvRjotNMusU2/sIN1Ibxg8dhu+xHCvbmVJsxNGcje2aImSYVhviJhBrInbyJ9rjA/HWaIW5qTqTaC+BzQZwx3pigyRYTZlzbUwm7/U9yoMexoljXZ6yDXLagnmEU+W0wD1//ddEwc/Nhyfw7SOYaO0R1vEDVbJRbpXMGr/IuV9Pr8OY/iBXJu74MgiorRuD9xsw';

const _quarkUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.14.2 Chrome/112.0.5615.165 Electron/24.1.3.8 Safari/537.36 Channel/pckk_other_ch';
const _chromeUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const _exoUa = 'ExoPlayerLib/2.19.1';

final _dio = Dio(BaseOptions(
  validateStatus: (s) => s != null && s < 600,
));

Future<String> fetchUrl() async {
  final r = await _dio.post(
    'https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc',
    options: Options(headers: {
      'User-Agent': _quarkUa,
      'Referer': 'https://pan.quark.cn/',
      'Cookie': _cookie,
      'content-type': 'application/json',
    }),
    data: {'fids': ['2f57a06b27b04c298a1781034997d784']},
  );
  print('API status=${r.statusCode}');
  final list = (r.data as Map<String, dynamic>)['data'] as List;
  return list[0]['download_url'] as String;
}

Future<void> head(String url, String label, Map<String, String> headers) async {
  final r = await _dio.head(url, options: Options(headers: headers));
  print('  $label -> ${r.statusCode} '
      'len=${r.headers.value('content-length')} '
      'type=${r.headers.value('content-type')}');
}

Future<void> main() async {
  final url = await fetchUrl();
  print('download_url host=${Uri.parse(url).host}\n');

  print('HEAD 测试各 UA:');
  await head(url, 'ExoPlayer UA        ', {'User-Agent': _exoUa});
  await head(url, 'Chrome UA           ', {'User-Agent': _chromeUa});
  await head(url, '无 UA               ', {});
  await head(url, 'quark-cloud UA      ', {'User-Agent': _quarkUa});
  await head(url, 'Chrome+Referer      ',
      {'User-Agent': _chromeUa, 'Referer': 'https://pan.quark.cn/'});
  await head(url, 'Chrome+Referer+Cookie', {
    'User-Agent': _chromeUa,
    'Referer': 'https://pan.quark.cn/',
    'Cookie': _cookie,
  });
  await head(url, '仅Cookie             ', {'Cookie': _cookie});
  await head(url, 'ExoUA+Cookie         ', {
    'User-Agent': _exoUa,
    'Cookie': _cookie,
  });
  await head(url, 'Cookie+Range         ', {
    'Cookie': _cookie,
    'Range': 'bytes=0-1023',
  });

  // GET + Range（播放器实际行为）
  final r = await _dio.get(url,
      options: Options(
        headers: {'Cookie': _cookie, 'Range': 'bytes=0-1023'},
        validateStatus: (s) => s != null && s < 600,
      ));
  print('  GET Range+Cookie    -> ${r.statusCode} '
      'len=${(r.data as List<int>).length}');

  exit(0);
}
