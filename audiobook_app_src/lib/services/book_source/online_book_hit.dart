import 'package:html/parser.dart' as html_parser;

/// online 型书源的一次命中：一本可直接在线收听的书。
///
/// 搜索页产出（书名 + 详情页链接），加入书架时再解析章节列表
/// （见 BookSourceEngine.resolveOnlineChapters）。
class OnlineBookHit {
  final String source;
  final String detailUrl;
  final String title;
  final String? author;

  OnlineBookHit({
    required this.source,
    required this.detailUrl,
    required this.title,
    this.author,
  });
}

/// 详情页解析出的一个在线章节（音频直链）。
class OnlineChapter {
  final String title;
  final String url;

  const OnlineChapter({required this.title, required this.url});
}

/// 详情页解析结果：章节列表 + 站点信息。
class OnlineBookDetail {
  final String? author;
  final List<OnlineChapter> chapters;

  const OnlineBookDetail({this.author, required this.chapters});
}

/// HTML 实体解码（&amp; &nbsp; &#39; …）。空串安全。
String decodeHtmlEntities(String? s) {
  if (s == null || s.isEmpty) return '';
  final text = html_parser.parseFragment(s).text ?? '';
  return text.trim();
}

/// 相对 URL → 绝对 URL（相对详情页所在目录）。
String resolveUrl(String base, String maybeRelative) {
  final u = Uri.tryParse(maybeRelative);
  if (u == null) return maybeRelative;
  if (u.isAbsolute) return maybeRelative;
  return Uri.parse(base).resolve(maybeRelative).toString();
}

/// 把一个详情页 JSON 转回 [OnlineBookHit]（书架缓存用）。
Map<String, dynamic> onlineHitToJson(OnlineBookHit hit) => {
      'source': hit.source,
      'detailUrl': hit.detailUrl,
      'title': hit.title,
      'author': hit.author,
    };

OnlineBookHit onlineHitFromJson(Map<String, dynamic> json) => OnlineBookHit(
      source: json['source']?.toString() ?? 'online',
      detailUrl: json['detailUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      author: json['author']?.toString(),
    );
