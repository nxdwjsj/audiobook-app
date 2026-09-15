import 'dart:convert';

/// 一个书源规则：描述「如何从某个网站发现夸克分享链接」。
///
/// 执行流程（由 BookSourceEngine 驱动）：
/// 1. 按 [queries] 模式从关键词生成 1..N 个查询词
/// 2. 对每个查询词 × 每个 [variants]，渲染 [urlTemplate] 并请求
/// 3. 响应处理：
///    - 若有 [jsonToArray]：从 JSON 数组取 [textFields] 拼接成纯文本
///    - 若有 [listLinkPattern]：提取文章链接列表（[urlGroup]/[titleGroup]），
///      链接本身是分享链接则直接用，否则请求文章页再提取
///    - 否则：对响应全文直接做分享链接提取
/// 4. 分享链接提取：[sharePattern] 抠 pwdId，[passcodeWindow] 窗口内
///    用 [passcodePattern] 猜提取码
class BookSource {
  final String id;
  final String name;

  /// 源类型：
  /// - quark（默认）：发现夸克分享链接（pwdId + 提取码），走网盘导入
  /// - online：在线听书站，搜索出详情页 → 解析章节列表 → 音频直链播放
  final String type;

  /// 0 = 策展类渠道（提取码通常准确）；1 = 其它（如 B 站，码多为推测）。
  /// 同一分享被多渠道发现时保留 rank 更小的渠道的提取码。
  final int rank;

  /// 查询词生成模式：
  /// - full：仅完整关键词
  /// - fullPlusQuark：「关键词 夸克」+ 完整关键词（B 站用）
  /// - tokens2 / tokens3：取前 2 / 3 个分词（多分词时附加完整关键词）
  /// - none：不生成查询词（固定列表页）
  final String queries;

  /// GET / POST。
  final String method;

  /// URL 模板。占位符：{{key}}（自动 URL 编码）、{{variant}}。
  final String urlTemplate;

  /// {{variant}} 占位符的取值列表。为空表示 URL 无变体。
  final List<String> variants;

  /// 搜索请求附加 headers。
  final Map<String, String> headers;

  /// POST 表单体（值支持 {{key}} 占位符）。
  final Map<String, String>? body;

  /// 反爬支持。目前仅 'bilibili'（内置 buvid Cookie + 412 重试）。
  final String? antiBlock;

  /// 响应为 JSON 时：取此路径下的数组（如 'data.result'）。
  final String? jsonToArray;

  /// [jsonToArray] 每一项里要拼接成文本的字段名。
  final List<String> textFields;

  /// 搜索页上提取「文章链接 + 标题」的正则。
  final String? listLinkPattern;

  /// [listLinkPattern] 中 URL 的捕获组序号（默认 1）。
  final int urlGroup;

  /// [listLinkPattern] 中标题的捕获组序号（默认 2）。
  final int titleGroup;

  /// 每个搜索页最多跟进的文章数。
  final int maxLinks;

  /// 标题必须包含关键词的某个分词才跟进。
  final bool requireTokenInTitle;

  /// 每次请求后的延时（毫秒，实际会再加 0~150ms 抖动）。
  final int delayMs;

  /// 文章页请求附加 headers。
  final Map<String, String> detailHeaders;

  /// 分享链接正则（默认匹配夸克）。
  final String sharePattern;

  /// 提取码正则（在分享链接前后 [passcodeWindow] 字符窗口内匹配）。
  final String passcodePattern;

  final int passcodeWindow;

  // ----------------------------------------------------------------
  // online 型专用字段（quark 型忽略）
  // ----------------------------------------------------------------

  /// online：搜索结果页提取「详情页链接 + 书名」的正则。
  final String? onlineBookPattern;

  /// [onlineBookPattern] 中链接/书名的捕获组序号。
  final int onlineBookUrlGroup;
  final int onlineBookTitleGroup;

  /// online：详情页提取「章节标题 + 章节地址」的正则。
  /// 捕获组序号由 [onlineChapterTitleGroup] / [onlineChapterUrlGroup] 指定
  /// （默认 1 = 标题、2 = 地址）。
  final String? onlineChapterPattern;

  /// [onlineChapterPattern] 中标题/地址的捕获组序号。
  final int onlineChapterTitleGroup;
  final int onlineChapterUrlGroup;

  /// online：播放页提取音频直链的正则（捕获组 1 = 音频 URL）。
  /// 仅当 [onlineChapterPattern] 提取的章节地址是 HTML 播放页时使用。
  final String? onlineAudioPattern;

  /// online：详情页章节排列顺序。'asc'（默认，正序）/ 'desc'（最新在前，解析后反转）。
  final String onlineChapterOrder;

  /// online：音频请求 Referer（防盗链），默认取详情页所在目录。
  final String? onlineReferer;

  /// online：详情页作者正则（可选，仅用于展示）。
  final String? onlineAuthorPattern;

  const BookSource({
    required this.id,
    required this.name,
    this.type = 'quark',
    this.rank = 1,
    this.queries = 'full',
    this.method = 'GET',
    required this.urlTemplate,
    this.variants = const [],
    this.headers = const {},
    this.body,
    this.antiBlock,
    this.jsonToArray,
    this.textFields = const [],
    this.listLinkPattern,
    this.urlGroup = 1,
    this.titleGroup = 2,
    this.maxLinks = 3,
    this.requireTokenInTitle = false,
    this.delayMs = 120,
    this.detailHeaders = const {},
    this.sharePattern = r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)',
    this.passcodePattern =
        r'(?:提取码|密码|pwd|passcode)\s*[:：]?\s*([0-9a-zA-Z]{4})\b',
    this.passcodeWindow = 200,
    this.onlineBookPattern,
    this.onlineBookUrlGroup = 1,
    this.onlineBookTitleGroup = 2,
    this.onlineChapterPattern,
    this.onlineChapterTitleGroup = 1,
    this.onlineChapterUrlGroup = 2,
    this.onlineAudioPattern,
    this.onlineChapterOrder = 'asc',
    this.onlineReferer,
    this.onlineAuthorPattern,
  });

  bool get isOnline => type == 'online';

  /// URL 的 host，用于管理页展示。
  String get host {
    final m = RegExp(r'https?://([^/]+)').firstMatch(urlTemplate);
    return m?.group(1) ?? urlTemplate;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (type != 'quark') 'type': type,
        if (rank != 1) 'rank': rank,
        if (queries != 'full') 'queries': queries,
        if (method != 'GET') 'method': method,
        'url': urlTemplate,
        if (variants.isNotEmpty) 'variants': variants,
        if (headers.isNotEmpty) 'headers': headers,
        if (body != null) 'body': body,
        if (antiBlock != null) 'antiBlock': antiBlock,
        if (jsonToArray != null) 'jsonToArray': jsonToArray,
        if (textFields.isNotEmpty) 'textFields': textFields,
        if (listLinkPattern != null) 'listLinkPattern': listLinkPattern,
        if (urlGroup != 1) 'urlGroup': urlGroup,
        if (titleGroup != 2) 'titleGroup': titleGroup,
        if (maxLinks != 3) 'maxLinks': maxLinks,
        if (requireTokenInTitle) 'requireTokenInTitle': requireTokenInTitle,
        if (delayMs != 120) 'delayMs': delayMs,
        if (detailHeaders.isNotEmpty) 'detailHeaders': detailHeaders,
        if (sharePattern != r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)')
          'sharePattern': sharePattern,
        if (passcodePattern !=
            r'(?:提取码|密码|pwd|passcode)\s*[:：]?\s*([0-9a-zA-Z]{4})\b')
          'passcodePattern': passcodePattern,
        if (passcodeWindow != 200) 'passcodeWindow': passcodeWindow,
        if (onlineBookPattern != null) 'onlineBookPattern': onlineBookPattern,
        if (onlineBookUrlGroup != 1) 'onlineBookUrlGroup': onlineBookUrlGroup,
        if (onlineBookTitleGroup != 2)
          'onlineBookTitleGroup': onlineBookTitleGroup,
        if (onlineChapterPattern != null)
          'onlineChapterPattern': onlineChapterPattern,
        if (onlineChapterTitleGroup != 1)
          'onlineChapterTitleGroup': onlineChapterTitleGroup,
        if (onlineChapterUrlGroup != 2)
          'onlineChapterUrlGroup': onlineChapterUrlGroup,
        if (onlineAudioPattern != null) 'onlineAudioPattern': onlineAudioPattern,
        if (onlineChapterOrder != 'asc') 'onlineChapterOrder': onlineChapterOrder,
        if (onlineReferer != null) 'onlineReferer': onlineReferer,
        if (onlineAuthorPattern != null)
          'onlineAuthorPattern': onlineAuthorPattern,
      };

  /// 解析并校验一个书源 JSON。失败抛 [FormatException]（带可读原因）。
  factory BookSource.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const FormatException('缺少 id 字段');
    }
    final name = json['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException('缺少 name 字段');
    }
    final url = json['url']?.toString().trim() ?? json['urlTemplate']?.toString().trim() ?? '';
    if (url.isEmpty) {
      throw const FormatException('缺少 url 字段（搜索入口 URL 模板）');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw const FormatException('url 必须以 http:// 或 https:// 开头');
    }

    // 预校验正则，导入时就把语法错误暴露出来
    String checkPattern(String key, String def) {
      final v = json[key]?.toString() ?? def;
      try {
        RegExp(v);
      } on FormatException catch (e) {
        throw FormatException('$key 不是合法正则：${e.message}');
      }
      return v;
    }

    final listLink = json['listLinkPattern']?.toString();
    if (listLink != null && listLink.isNotEmpty) {
      try {
        RegExp(listLink);
      } on FormatException catch (e) {
        throw FormatException('listLinkPattern 不是合法正则：${e.message}');
      }
    }

    // online 型必备字段
    final type = json['type']?.toString() ?? 'quark';
    if (type != 'quark' && type != 'online') {
      throw FormatException('type 只支持 quark / online，收到「$type」');
    }
    String? checkOnline(String key) {
      final v = json[key]?.toString().trim();
      if (v == null || v.isEmpty) return null;
      try {
        RegExp(v);
      } on FormatException catch (e) {
        throw FormatException('$key 不是合法正则：${e.message}');
      }
      return v;
    }

    final onlineBook = type == 'online' ? checkOnline('onlineBookPattern') : null;
    final onlineChapter =
        type == 'online' ? checkOnline('onlineChapterPattern') : null;
    final onlineAudio = type == 'online' ? checkOnline('onlineAudioPattern') : null;
    if (type == 'online' && (onlineBook == null || onlineChapter == null)) {
      throw const FormatException(
          'type=online 必须提供 onlineBookPattern 与 onlineChapterPattern');
    }
    final chapterOrder = json['onlineChapterOrder']?.toString() ?? 'asc';
    if (chapterOrder != 'asc' && chapterOrder != 'desc') {
      throw const FormatException(
          'onlineChapterOrder 只支持 asc / desc');
    }

    Map<String, String> mapOf(Object? v) => v is Map
        ? v.map((k, e) => MapEntry(k.toString(), e.toString()))
        : const {};

    return BookSource(
      id: id,
      name: name,
      type: type,
      rank: (json['rank'] as num?)?.toInt() ?? 1,
      queries: json['queries']?.toString() ?? 'full',
      method: (json['method']?.toString() ?? 'GET').toUpperCase(),
      urlTemplate: url,
      variants: (json['variants'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      headers: mapOf(json['headers']),
      body: json['body'] is Map
          ? mapOf(json['body'])
          : (json['body'] is String ? null : null),
      antiBlock: json['antiBlock']?.toString(),
      jsonToArray: json['jsonToArray']?.toString(),
      textFields: (json['textFields'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      listLinkPattern:
          (listLink == null || listLink.isEmpty) ? null : listLink,
      urlGroup: (json['urlGroup'] as num?)?.toInt() ?? 1,
      titleGroup: (json['titleGroup'] as num?)?.toInt() ?? 2,
      maxLinks: (json['maxLinks'] as num?)?.toInt() ?? 3,
      requireTokenInTitle: json['requireTokenInTitle'] as bool? ?? false,
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 120,
      detailHeaders: mapOf(json['detailHeaders']),
      sharePattern: checkPattern('sharePattern',
          r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)'),
      passcodePattern: checkPattern('passcodePattern',
          r'(?:提取码|密码|pwd|passcode)\s*[:：]?\s*([0-9a-zA-Z]{4})\b'),
      passcodeWindow: (json['passcodeWindow'] as num?)?.toInt() ?? 200,
      onlineBookPattern: onlineBook,
      onlineBookUrlGroup: (json['onlineBookUrlGroup'] as num?)?.toInt() ?? 1,
      onlineBookTitleGroup:
          (json['onlineBookTitleGroup'] as num?)?.toInt() ?? 2,
      onlineChapterPattern: onlineChapter,
      onlineChapterTitleGroup:
          (json['onlineChapterTitleGroup'] as num?)?.toInt() ?? 1,
      onlineChapterUrlGroup:
          (json['onlineChapterUrlGroup'] as num?)?.toInt() ?? 2,
      onlineAudioPattern: onlineAudio,
      onlineChapterOrder: chapterOrder,
      onlineReferer: json['onlineReferer']?.toString(),
      onlineAuthorPattern: type == 'online'
          ? checkOnline('onlineAuthorPattern')
          : null,
    );
  }

  /// 便捷序列化（导入导出用，带缩进）。
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
