import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/services/book_source/book_source.dart';
import 'package:audiobook_app/services/book_source/book_source_engine.dart';

void main() {
  group('BookSource online 型模型', () {
    test('fromJson 解析 online 源', () {
      final s = BookSource.fromJson({
        'id': 'test_online',
        'name': '测试在线站',
        'type': 'online',
        'url': 'https://example.com/search?q={{key}}',
        'onlineBookPattern':
            r'<a href="(https://example\.com/book/\d+\.html)"[^>]*>([^<]+)</a>',
        'onlineChapterPattern':
            r'<a[^>]+href="([^"]+\.mp3)"[^>]*>([^<]+)</a>',
      });
      expect(s.type, 'online');
      expect(s.isOnline, isTrue);
      expect(s.onlineBookPattern, isNotNull);
      expect(s.onlineChapterPattern, isNotNull);
      // 往返
      final s2 = BookSource.fromJson(s.toJson());
      expect(s2.isOnline, isTrue);
      expect(s2.onlineBookPattern, s.onlineBookPattern);
      expect(s2.onlineChapterPattern, s.onlineChapterPattern);
    });

    test('online 缺必备字段时报错', () {
      expect(
        () => BookSource.fromJson({
          'id': 'bad',
          'name': '坏源',
          'type': 'online',
          'url': 'https://example.com/s?q={{key}}',
        }),
        throwsFormatException,
      );
    });

    test('未知 type 报错', () {
      expect(
        () => BookSource.fromJson({
          'id': 'bad',
          'name': '坏源',
          'type': 'baidu',
          'url': 'https://example.com/s?q={{key}}',
        }),
        throwsFormatException,
      );
    });

    test('无 type 默认为 quark', () {
      final s = BookSource.fromJson({
        'id': 'q',
        'name': '夸克源',
        'url': 'https://example.com/s?q={{key}}',
      });
      expect(s.type, 'quark');
      expect(s.isOnline, isFalse);
    });
  });

  group('BookSourceEngine online 解析', () {
    const source = BookSource(
      id: 't',
      name: 't',
      type: 'online',
      urlTemplate: 'https://example.com/search?q={{key}}',
      onlineBookPattern:
          r'<a href="(https://example\.com/book/(\d+)\.html)"[^>]*>([^<]+)</a>',
      onlineChapterPattern:
          r'title="([^"]+)"[^>]*href="([^"]+\.mp3)"',
      onlineBookUrlGroup: 1,
      onlineBookTitleGroup: 3,
    );

    test('parseOnlineDetail 提取章节并转绝对地址', () {
      final engine = BookSourceEngine(source);
      final detail = engine.parseOnlineDetail('''
        <ul>
          <li><a title="第1集" href="/audio/ep1.mp3">第1集</a></li>
          <li><a title="第2集" href="https://cdn.example.com/audio/ep2.mp3">第2集</a></li>
          <li><a title="重复集" href="/audio/ep1.mp3">重复</a></li>
        </ul>
      ''', 'https://example.com/book/123.html');
      expect(detail.chapters.length, 2);
      expect(detail.chapters[0].url,
          'https://example.com/audio/ep1.mp3');
      expect(detail.chapters[1].url,
          'https://cdn.example.com/audio/ep2.mp3');
      expect(detail.chapters[0].title, '第1集');
    });

    test('无匹配返回空列表', () {
      final engine = BookSourceEngine(source);
      final detail = engine.parseOnlineDetail(
          '<html><body>啥都没有</body></html>',
          'https://example.com/book/1.html');
      expect(detail.chapters, isEmpty);
    });

    test('onlineChapterOrder=desc 时反转章节顺序', () {
      const descSource = BookSource(
        id: 'd',
        name: 'd',
        type: 'online',
        urlTemplate: 'https://example.com/so/{{key}}/',
        onlineBookPattern: r'<a href="(/book/\d+/)"[^>]*title="([^"]+)"',
        onlineChapterPattern: r'href="([^"]+)"[^>]*title="([^"]+)"',
        onlineChapterTitleGroup: 2,
        onlineChapterUrlGroup: 1,
        onlineChapterOrder: 'desc',
      );
      final engine = BookSourceEngine(descSource);
      final detail = engine.parseOnlineDetail('''
        <li><a href="/book/x/3.html" title="第3集"></a></li>
        <li><a href="/book/x/2.html" title="第2集"></a></li>
        <li><a href="/book/x/1.html" title="第1集"></a></li>
      ''', 'https://example.com/book/x/');
      expect(detail.chapters.length, 3);
      expect(detail.chapters[0].title, '第1集');
      expect(detail.chapters[2].title, '第3集');
    });
  });

  group('听书网（tingshuwang）真实结构', () {
    // 与 builtin_sources.dart 中 tingshuwang 源一致的结构样本
    const tswSource = BookSource(
      id: 'tingshuwang',
      name: '听书网',
      type: 'online',
      urlTemplate: 'https://www.tingshuwang.cc/so/{{key}}/',
      onlineBookPattern: r'<h5><a href="(/book/[^"]+/)"[^>]*title="([^"]+)"',
      onlineChapterPattern:
          r'<li><a href="(/book/[^"]+/\d+\.html)"[^>]*title="([^"]+)"',
      onlineChapterTitleGroup: 2,
      onlineChapterUrlGroup: 1,
      onlineChapterOrder: 'desc',
      onlineAudioPattern: r"videourl:\s*'([^']+)'",
      onlineAuthorPattern: r'class="author">作者：<a[^>]*>([^<]+)</a>',
      maxLinks: 10,
      delayMs: 200,
    );

    test('搜索结果页正则命中详情页链接（不受侧栏干扰）', () {
      final engine = BookSourceEngine(tswSource);
      // 模拟：搜索结果 + 侧栏排行榜（无 <h5> 前缀）
      final re = RegExp(tswSource.onlineBookPattern!);
      final m = re.firstMatch(
          '<h5><a href="/book/GuiBiZhiZhu/" target="_blank" title="诡秘之主">诡秘之主</a></h5>');
      expect(m, isNotNull);
      expect(m!.group(1), '/book/GuiBiZhiZhu/');
      expect(m.group(2), '诡秘之主');
      // 侧栏排行榜链接（<li> 内、非 <h5>）不应被 book 正则匹配
      final side = re.firstMatch(
          '<li><a href="/book/ShenYiMaMiYouLengYouTianYanQingXiao/" title="神医妈咪又冷又甜" target="_blank">神医妈咪</a></li>');
      expect(side, isNull);
      expect(engine, isNotNull);
    });

    test('详情页章节解析：href 在 title 前的组序 + desc 反转 + 作者', () {
      final engine = BookSourceEngine(tswSource);
      final detail = engine.parseOnlineDetail('''
        <div class="author">作者：<a href="/author/x/" title="x的有声小说">爱潜水的乌贼</a></div>
        <ul>
          <li><a href="/book/GuiBiZhiZhu/166550.html" target="_self" title="诡秘之主 诡秘之主第2052-2059集（番外）">…</a></li>
          <li><a href="/book/GuiBiZhiZhu/166140.html" target="_self" title="诡秘之主 诡秘之主第001-005集">…</a></li>
        </ul>
      ''', 'https://www.tingshuwang.cc/book/GuiBiZhiZhu/');
      expect(detail.chapters.length, 2);
      // desc：最新在前 → 反转后第一集在最前
      expect(detail.chapters[0].url,
          'https://www.tingshuwang.cc/book/GuiBiZhiZhu/166140.html');
      expect(detail.chapters[0].title, '诡秘之主 诡秘之主第001-005集');
      expect(detail.chapters[1].title, '诡秘之主 诡秘之主第2052-2059集（番外）');
      expect(detail.author, '爱潜水的乌贼');
    });

    test('播放页正则提取 videourl 音频直链', () {
      const html = '''
        <script>
          var videourl:'https://www.tingshuwang.cc/d/file/yt/14207/2052-2059.mp3',
        </script>
      ''';
      final re = RegExp(tswSource.onlineAudioPattern!);
      final m = re.firstMatch(html);
      expect(m, isNotNull);
      expect(m!.group(1),
          'https://www.tingshuwang.cc/d/file/yt/14207/2052-2059.mp3');
    });
  });

  group('13 听书网（ting13）真实结构', () {
    // 与 builtin_sources.dart 中 ting13 源一致的结构样本
    const t13Source = BookSource(
      id: 'ting13',
      name: '13听书网',
      type: 'online',
      method: 'POST',
      urlTemplate: 'https://m.ting13.cc/novelsearch/search/result.html',
      body: {'searchword': '{{key}}'},
      onlineApiTemplate:
          'https://m.ting13.cc/api/ajax/solist?word={{key}}&type=name&page=1&order=1',
      onlineBookPattern:
          r'"novel":\s*\{\s*"name":"([^"]+)"[^{}]*?"url":"([^"]+)"',
      onlineBookTitleGroup: 1,
      onlineBookUrlGroup: 2,
      onlineDirPattern: r'href="(/tingdirs/[^"]+\.html)"',
      onlineDirPageParam: 'page',
      onlineDirMaxPages: 80,
      onlineChapterPattern:
          r'<a[^>]*href="(/play/[\d_/]+\.html)"[^>]*title="([^"]+)"',
      onlineChapterTitleGroup: 2,
      onlineChapterUrlGroup: 1,
      onlineChapterOrder: 'asc',
      onlineAudioPattern:
          r'''(?:src|url|mp3|m4a|audio|source)["']?\s*[:=]\s*["']?(https?://[^"'\s<>\\]+\.(?:mp3|m4a|aac|ogg|opus)(?:\?[^"'\s<>\\]*)?)''',
      browserFetch: true,
    );

    test('搜索接口 JSON 命中书名与详情页链接', () {
      const json = '{"type":1,"cnum":4,"data":[{"data":{"allvisit":"2.53万"},'
          '"boyin":{"name":"曲中人工作室"},'
          '"novel":{"name":"诡秘之主",'
          '"cover":"https://image.itingshu.net/cover/yousheng/x.gif",'
          '"url":"/youshengxiaoshuo/38968/","intro":"蒸汽与机械的浪潮中…"}}]}';
      final m = RegExp(t13Source.onlineBookPattern!).firstMatch(json);
      expect(m, isNotNull);
      expect(m!.group(1), '诡秘之主');
      expect(m.group(2), '/youshengxiaoshuo/38968/');
    });

    test('详情页能抠出完整目录链接', () {
      final m = RegExp(t13Source.onlineDirPattern!).firstMatch(
          '<span class="more fr"><a href="/tingdirs/UBuaOrJc/cbbhASajUEujOrEd.html"'
          'style="color:#fff;">全部章节</a></span>');
      expect(m, isNotNull);
      expect(m!.group(1), '/tingdirs/UBuaOrJc/cbbhASajUEujOrEd.html');
    });

    test('目录页章节解析：href 与 title 紧邻、正序、两种路径格式都收', () {
      final engine = BookSourceEngine(t13Source);
      final detail = engine.parseOnlineDetail('''
        <div class="play-list"><ul style="width: 100%;">
          <li><a href="/play/38968_1_207153.html"title="第1集_绯红"><span>12-04</span>第1集_绯红</a></li>
          <li><a href="/play/38968_1/207154.html"title="第2集_绯红_1"><span>12-04</span>第2集_绯红_1</a></li>
        </ul></div>
      ''', 'https://m.ting13.cc/tingdirs/UBuaOrJc/cbbhASajUEujOrEd.html');
      expect(detail.chapters.length, 2);
      expect(detail.chapters[0].url,
          'https://m.ting13.cc/play/38968_1_207153.html');
      expect(detail.chapters[0].title, '第1集_绯红');
      expect(detail.chapters[1].url,
          'https://m.ting13.cc/play/38968_1/207154.html');
      // 正序站点不做反转
      expect(detail.chapters[1].title, '第2集_绯红_1');
    });

    test('播放页音频正则兼容常见写法', () {
      final re = RegExp(t13Source.onlineAudioPattern!);
      const samples = [
        '<audio id="player" src="https://cdn.iting13.com/a/38968/1.m4a"></audio>',
        "<script>var url = 'https://cdn.iting13.com/a/38968/1.mp3';</script>",
        '{"mp3":"https://cdn.iting13.com/a/38968/1.mp3?sign=abc"}',
      ];
      for (final html in samples) {
        final m = re.firstMatch(html);
        expect(m, isNotNull, reason: html);
        expect(m!.group(1), startsWith('https://cdn.iting13.com/'));
        expect(m.group(1), contains(RegExp(r'\.(mp3|m4a)')));
      }
    });

    test('新增字段能序列化往返', () {
      final back = BookSource.fromJson(t13Source.toJson());
      expect(back.browserFetch, isTrue);
      expect(back.onlineDirPageParam, 'page');
      expect(back.onlineDirMaxPages, 80);
      expect(back.onlineDirPattern, isNotNull);
      expect(back.onlineApiTemplate, contains('/api/ajax/solist'));
    });

    test('onlineApiTemplate 不是绝对地址时报错', () {
      expect(
        () => BookSource.fromJson({
          'id': 'x',
          'name': 'x',
          'type': 'online',
          'url': 'https://a.com/s',
          'onlineBookPattern': r'a',
          'onlineChapterPattern': r'b',
          'onlineApiTemplate': '/api/only/path',
        }),
        throwsFormatException,
      );
    });
  });
}
