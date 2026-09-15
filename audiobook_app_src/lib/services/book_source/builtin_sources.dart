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

  // ------------------------------------------------------------------
  // 13 听书网（移动站 m.ting13.cc）
  //
  // 反爬较强：
  // - 搜索结果由页面 JS 拉接口渲染，页面本身不含数据，且接口要求先有会话
  //   Cookie → 用 POST 搜索入口预热建会话，再请求 JSON 接口
  // - 目录页（/tingdirs）与播放页（/play）有 JS 挑战（__51guid__）以及
  //   请求头指纹校验，普通 HTTP 客户端会被 403 挡住
  //   → 页面抓取走离屏 WebView（browserFetch: true）
  // ------------------------------------------------------------------
  BookSource(
    id: 'ting13',
    name: '13听书网',
    type: 'online',
    queries: 'full',
    method: 'POST',
    // 搜索入口只用于建立会话（拿 PHPSESSID），页面本身不含结果
    urlTemplate: 'https://m.ting13.cc/novelsearch/search/result.html',
    body: {'searchword': '{{key}}'},
    headers: {
      'Referer': 'https://m.ting13.cc/novelsearch/search/result.html',
      'X-Requested-With': 'XMLHttpRequest',
    },
    // 真正的搜索结果接口，返回：
    // {"novel":{"name":"诡秘之主","cover":"https://…gif","url":"/youshengxiaoshuo/38968/",…}}
    onlineApiTemplate:
        'https://m.ting13.cc/api/ajax/solist?word={{key}}&type=name&page=1&order=1',
    onlineBookPattern:
        r'"novel":\s*\{\s*"name":"([^"]+)"[^{}]*?"url":"([^"]+)"',
    onlineBookTitleGroup: 1,
    onlineBookUrlGroup: 2,
    maxLinks: 10,
    delayMs: 120,
    // 详情页只列最新 10 章，完整目录在 /tingdirs/：
    // <a href="/tingdirs/UBuaOrJc/cbbhASajUEujOrEd.html" …>全部章节</a>
    onlineDirPattern: r'href="(/tingdirs/[^"]+\.html)"',
    // 目录页分页：?page=2&sort=asc（每页 60 集）
    onlineDirPageParam: 'page',
    onlineDirMaxPages: 80,
    // 章节：移动站 <a href="/play/38968_1_230902.html"title="第3218集_…">
    // 桌面站是 <a href="/play/38968_1/207153.html"title="第1集_绯红">，路径里多一层
    // 所以路径放宽成「数字/下划线/斜杠」都收
    onlineChapterPattern:
        r'<a[^>]*href="(/play/[\d_/]+\.html)"[^>]*title="([^"]+)"',
    onlineChapterTitleGroup: 2,
    onlineChapterUrlGroup: 1,
    onlineChapterOrder: 'asc',
    // 播放页里的音频地址：站点写法未完全固定，用宽松正则兜住常见形式
    onlineAudioPattern: r'''(?:src|url|mp3|m4a|audio|source)["']?\s*[:=]\s*["']?(https?://[^"'\s<>\\]+\.(?:mp3|m4a|aac|ogg|opus)(?:\?[^"'\s<>\\]*)?)''',
    browserFetch: true,
  ),

  // ------------------------------------------------------------------
  // 275 听书（m.i275.com）
  //
  // 无 JS 挑战、无接口：搜索与详情页都是服务端渲染，普通 HTTP 就能抓。
  // 唯一要求：播放页必须先有会话 Cookie（直接请求会 302 回首页），
  // 引擎的 Cookie jar 会在抓详情页时自动收下 PHPSESSID。
  // ------------------------------------------------------------------
  BookSource(
    id: 'i275',
    name: '275听书',
    type: 'online',
    queries: 'full',
    urlTemplate: 'https://m.i275.com/search.php?q={{key}}',
    headers: {
      // 站点是移动站，用移动 UA 保证拿到同一套服务端渲染结构
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-S9010) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 '
          'Mobile Safari/537.36',
    },
    // 搜索结果：<a href="/book/138.html" class="flex p-4 …">
    //              <img … alt="龙族">…<h3 class="…truncate">龙族</h3>
    onlineBookPattern:
        r'<a href="(/book/\d+\.html)" class="flex p-4[\s\S]{0,900}?<h3[^>]*>([^<]+)</h3>',
    onlineBookTitleGroup: 2,
    onlineBookUrlGroup: 1,
    maxLinks: 10,
    delayMs: 150,
    // 详情页一页给全（实测 1100+ 集，无需翻页）：
    // <a id="chapter-pos-1" href="/play/138/198329.html" class="…">
    //   <span class="…w-10">1.</span>
    //   <span class="text-sm text-gray-700 truncate">正文在↓下面</span>
    onlineChapterPattern:
        r'<a id="chapter-pos-\d+"\s*href="(/play/\d+/\d+\.html)"[\s\S]{0,400}?<span class="text-sm text-gray-700 truncate">([^<]+)</span>',
    onlineChapterTitleGroup: 2,
    onlineChapterUrlGroup: 1,
    onlineChapterOrder: 'asc',
    // 播放页 APlayer 初始化里的音频地址（注意是 http，且斜杠被转义成 \/）：
    // url: "http:\/\/audiopay.cos.tx.xmcdn.com\/…\/xxx-aacv2-48K.m4a?sign=…"
    onlineAudioPattern:
        r'url:\s*"(https?:(?:\\?/){2}[^"]+\.(?:m4a|mp3|aac|ogg)[^"]*)"',
    // 抓详情页/播放页时带站点 Referer（音频本身在腾讯云 COS，
    // 签名参数已带授权，播放时不需要 Referer）
    onlineReferer: 'https://m.i275.com/',
  ),
];

/// 内置源的 id 集合。
final Set<String> kBuiltinSourceIds =
    kBuiltinBookSources.map((s) => s.id).toSet();
