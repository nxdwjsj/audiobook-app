import 'book_source.dart';

/// 内置书源（与旧版硬编码渠道一一对应）。
///
/// 这些源随 App 发布、只读不可删除；用户自建/导入的源存 Hive。
/// 站点改版时更新此列表发版即可，用户也可用同 id 导入覆盖内置规则。
const List<BookSource> kBuiltinBookSources = [
  // ----------------------------------------------------------------
  // B 站搜索（JSON 接口 + 反爬 + 「关键词 夸克」双查询）
  // ----------------------------------------------------------------
  BookSource(
    id: 'bilibili',
    name: 'B站搜索',
    rank: 1,
    queries: 'fullPlusQuark',
    urlTemplate: 'https://api.bilibili.com/x/web-interface/search/type'
        '?search_type=video&keyword={{key}}&page=1&page_size=20',
    antiBlock: 'bilibili',
    jsonToArray: 'data.result',
    textFields: ['title', 'description', 'tag'],
  ),

  // ----------------------------------------------------------------
  // 第一故事（4 个板块变体 × 分词查询，搜索页提取文章链接再进详情页）
  // ----------------------------------------------------------------
  BookSource(
    id: 'yigushi',
    name: '第一故事',
    rank: 0,
    queries: 'tokens3',
    urlTemplate: 'https://www.yigushi.com/{{variant}}/search.php?kw={{key}}',
    variants: ['youshengxiaoshuo', 'soft', 'xiqu', 'baby'],
    listLinkPattern:
        r'<a href="(https://www\.yigushi\.com/[^"]+\.html)"[^>]*?target="_blank"[^>]*?title="([^"]+)"',
    maxLinks: 3,
    requireTokenInTitle: true,
    delayMs: 120,
  ),

  // ----------------------------------------------------------------
  // Mp3 故事网（POST 搜索）
  // ----------------------------------------------------------------
  BookSource(
    id: 'yangzhiyi',
    name: 'Mp3故事网',
    rank: 0,
    queries: 'tokens2',
    method: 'POST',
    urlTemplate: 'https://mp3.yangzhiyi.com/zb_system/cmd.php?act=search',
    body: {'q': '{{key}}'},
    listLinkPattern:
        r'<h2[^>]*>\s*<a href="(https://mp3\.yangzhiyi\.com/[^"]+\.html)"[^>]*title="([^"]+)"',
    maxLinks: 3,
    requireTokenInTitle: true,
    delayMs: 120,
  ),

  // ----------------------------------------------------------------
  // slowread（固定列表页，标题过滤在文章链接正则的第二个捕获组上做）
  // ----------------------------------------------------------------
  BookSource(
    id: 'slowread',
    name: 'slowread',
    rank: 0,
    // 固定列表页不随关键词变化，但标题过滤仍依赖关键词
    queries: 'full',
    urlTemplate: 'https://slowread.net/k/audiobook.html',
    listLinkPattern:
        r"<span>([^<]+)</span>\s*<a href='(https://pan\.quark\.cn/s/[0-9a-zA-Z_-]+)'",
    urlGroup: 2,
    titleGroup: 1,
    maxLinks: 5,
    requireTokenInTitle: true,
    delayMs: 0,
  ),

  // ----------------------------------------------------------------
  // 放空一夏（搜索页直接提取分享链接，无文章跳转）
  // ----------------------------------------------------------------
  BookSource(
    id: 'fangkong',
    name: '放空一夏',
    rank: 0,
    urlTemplate: 'https://fangkong.cc/s/{{key}}.html',
  ),

  // ----------------------------------------------------------------
  // 听书网（在线听书站，两级结构：详情页章节列表 → 播放页懒解析音频直链）
  // ----------------------------------------------------------------
  BookSource(
    id: 'tingshuwang',
    name: '听书网',
    rank: 0,
    type: 'online',
    queries: 'full',
    urlTemplate: 'https://www.tingshuwang.cc/so/{{key}}/',
    // 搜索结果：<h5><a href="/book/GuiBiZhiZhu/" title="诡秘之主">诡秘之主</a></h5>
    // 限定 <h5> 避免误匹配侧栏排行榜的 /book/ 链接
    onlineBookPattern:
        r'<h5><a href="(/book/[^"]+/)"[^>]*title="([^"]+)"',
    maxLinks: 10,
    requireTokenInTitle: false,
    delayMs: 200,
    // 详情页：<li><a href="/book/GuiBiZhiZhu/166550.html" target="_self" title="诡秘之主 诡秘之主第2052-2059集（番外）">
    // href 在 title 前面（组序与默认相反），标题里会重复书名（展示时可去重）
    onlineChapterPattern:
        r'<li><a href="(/book/[^"]+/\d+\.html)"[^>]*title="([^"]+)"',
    onlineChapterTitleGroup: 2,
    onlineChapterUrlGroup: 1,
    // 站点把最新章节排在前面
    onlineChapterOrder: 'desc',
    // 播放页 JS 变量：videourl:'https://www.tingshuwang.cc/d/file/yt/14207/2052-2059.mp3',
    onlineAudioPattern: r"videourl:\s*'([^']+)'",
    // 详情页作者：<span class="author">作者：<a ...>爱潜水的乌贼</a>
    onlineAuthorPattern:
        r'class="author">作者：<a[^>]*>([^<]+)</a>',
  ),
];

/// 内置源的 id 集合。
final Set<String> kBuiltinSourceIds =
    kBuiltinBookSources.map((s) => s.id).toSet();
