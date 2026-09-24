import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 统一封面组件（设计规范 §4）。
///
/// 全应用**只有这一处**负责渲染封面：任何页面需要封面都必须用 [BookCover]，
/// 不要再写 `CachedNetworkImage` 或自绘渐变。
///
/// 三级降级顺序（规范 §4.1）：
/// 1. [customImagePath]：用户自选封面（本地文件）
/// 2. [networkCoverUrl]：网盘 / 书源自带封面
/// 3. 生成封面：由书名哈希取出版色 + 竖排书名，**不需要网络**，
///    因此「所有书立刻有体面封面」这一条永远成立
///
/// 封面比例由外部决定（规范要求 3:4 竖版），组件本身只负责填充。
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.title,
    this.author,
    this.customImagePath,
    this.networkCoverUrl,
    this.sourceLabel,
    this.progress,
    this.borderRadius,
    this.memCacheWidth = 300,
    this.fallbackChar = '书',
  });

  /// 书名。同时用于生成封面的选色与竖排取字。
  final String title;

  /// 作者 / 主播。生成封面上显示在短横线下方；为空则不画横线。
  final String? author;

  /// 用户自选封面（最高优先级）。
  final String? customImagePath;

  /// 网络封面 URL。
  final String? networkCoverUrl;

  /// 来源角标文案（夸克 / 百度 / 本地 / 在线…）。为空则不显示角标。
  final String? sourceLabel;

  /// 已听进度 0~1。为 null 或不大于 0 时不画底部进度条。
  final double? progress;

  /// 圆角。默认规范值 10。
  final BorderRadius? borderRadius;

  /// 解码宽度上限，控制内存（书架封面实际显示约 100~150dp）。
  final int memCacheWidth;

  /// 书名全空时的兜底字。
  final String fallbackChar;

  BorderRadius get _radius => borderRadius ?? BorderRadius.circular(10);

  @override
  Widget build(BuildContext context) {
    final image = _buildImage(context);
    final showBar = progress != null && progress! > 0;

    return ClipRRect(
      borderRadius: _radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (sourceLabel != null && sourceLabel!.isNotEmpty)
            Positioned(
              left: 6,
              top: 6,
              child: _SourceBadge(
                key: const ValueKey('book-cover-badge'),
                label: sourceLabel!,
              ),
            ),
          if (showBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ProgressEdge(
                key: const ValueKey('book-cover-progress'),
                value: progress!.clamp(0.0, 1.0),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final custom = customImagePath;
    if (custom != null && custom.isNotEmpty) {
      return Image.file(
        File(custom),
        fit: BoxFit.cover,
        cacheWidth: memCacheWidth,
        errorBuilder: (_, __, ___) => _GeneratedCover(
          title: title,
          author: author,
          fallbackChar: fallbackChar,
        ),
      );
    }
    final net = networkCoverUrl;
    if (net != null && net.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: net,
        fit: BoxFit.cover,
        memCacheWidth: memCacheWidth,
        placeholder: (_, __) => _GeneratedCover(
          title: title,
          author: author,
          fallbackChar: fallbackChar,
        ),
        errorWidget: (_, __, ___) => _GeneratedCover(
          title: title,
          author: author,
          fallbackChar: fallbackChar,
        ),
      );
    }
    return _GeneratedCover(
      title: title,
      author: author,
      fallbackChar: fallbackChar,
    );
  }
}

/// 分隔符：命中即认为其后是作者 / 演播 / 集数等附加信息。
const List<String> _coverTitleSeparators = <String>[
  '-', '–', '—', '_', '·', '|', '｜', '：', ':', '/', '\\',
];

/// 去掉标题里拼在后面的附加信息，只留主标题。
///
/// 仅当分隔符出现在第 2 个字之后才截断 —— 避免把 `G-诡秘之主`
/// 这类以分隔符开头的标题截成空串。
String coverCoreTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return t;
  for (final sep in _coverTitleSeparators) {
    final i = t.indexOf(sep);
    if (i >= 2) return t.substring(0, i).trim();
  }
  return t;
}

/// 生成封面上竖排显示的文字：主标题的前 [max] 个字素。
///
/// 用 `characters` 按**字素**切分，不用 `codeUnit` / `split('')`：
/// 生僻字与 emoji 是代理对，按码元切会切出半个字符，渲染成乱码方块。
String coverVerticalTitle(String title, String fallback, {int max = 4}) {
  final core = coverCoreTitle(title);
  if (core.isEmpty) return fallback;
  return core.characters.take(max).toString();
}

/// 生成封面（规范 §4.2）。
///
/// 版式：出版色底 → 内嵌细线框 → 竖排书名（≤4 字）→ 短横线 → 作者。
/// 刻意保持极简：装饰越少越接近印刷品，越不容易显廉价。
class _GeneratedCover extends StatelessWidget {
  const _GeneratedCover({
    required this.title,
    this.author,
    this.fallbackChar = '书',
  });

  final String title;
  final String? author;
  final String fallbackChar;

  /// 竖排最多取 4 个字。用 `characters` 而非 `codeUnit` 切分：
  /// 生僻字与 emoji 是代理对，按码元切会切出半个字符（乱码方块）。
  ///
  /// 先截「主标题」再取字：网盘目录名与书源标题常把作者拼在后面
  /// （如 `蛊真人-老宝玉`、`诡秘之主·多人有声剧`），若不先截断，
  /// 竖排里会混进一个孤零零的分隔符，排版立刻垮掉。
  @override
  Widget build(BuildContext context) {
    final bg = AppCoverPalette.colorFor(title);
    final chars = coverVerticalTitle(title, fallbackChar);
    // 注意：这里必须继续按**字素**切分。曾经写成 `chars.split('')`，
    // 那是按 UTF-16 码元切，会把代理对（生僻字 / emoji）切成半个字符，
    // 渲染成乱码方块 —— 前面用 characters 取的成果会被自己毁掉。
    final graphemes = chars.characters;
    final vertical = graphemes.join('\n');
    final lineCount = graphemes.length;
    final hasAuthor = author != null && author!.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pad = w * 0.075;

        // 字号按「可用高度 ÷ 字数」反推，保证 1~4 字都排得下且不溢出。
        // 可用高度取封面高度的 52%，给作者行与短横线留位置。
        final usable = h * 0.52;
        final fontSize =
            (usable / (lineCount * 1.16)).clamp(12.0, 34.0).toDouble();

        return Container(
          color: bg,
          padding: EdgeInsets.all(pad),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppCoverPalette.frame, width: 0.5),
            ),
            padding: EdgeInsets.symmetric(horizontal: pad * 0.5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  vertical,
                  textAlign: TextAlign.center,
                  maxLines: lineCount,
                  style: TextStyle(
                    color: AppCoverPalette.ink,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                    height: 1.16,
                  ),
                ),
                if (hasAuthor) ...[
                  SizedBox(height: h * 0.05),
                  Container(
                    width: w * 0.16,
                    height: 1,
                    color: AppCoverPalette.rule,
                  ),
                  SizedBox(height: h * 0.035),
                  Text(
                    author!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      // 0.95 而不是更低：更低的透明度会让「赭石」底色上的作者行
                      // 掉到 4:1 以下（实测 0.82 时为 3.98:1，不达 WCAG AA）。
                      // 0.95 在全部 8 个出版色上均 ≥ 4.7:1，见设计系统 §8。
                      color: AppCoverPalette.ink.withValues(alpha: 0.95),
                      fontSize: (w * 0.085).clamp(9.0, 13.0).toDouble(),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 来源角标（规范 §4.3）：纸白半透明底 + 墨色文字，不用彩色。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppCoverPalette.ink.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          height: 1.1,
          fontWeight: FontWeight.w400,
          color: Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

/// 贴底进度条（规范 §4.2）：2px、强调松绿。
class _ProgressEdge extends StatelessWidget {
  const _ProgressEdge({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: constraints.maxWidth * value,
          height: 2.5,
          color: AppInk.accent(Theme.of(context).brightness == Brightness.dark),
        ),
      ),
    );
  }
}
