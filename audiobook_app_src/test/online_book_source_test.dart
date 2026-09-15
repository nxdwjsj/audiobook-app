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
}
