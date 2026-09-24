import 'dart:io';
import 'dart:math' show pow;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/theme/app_tokens.dart';
import 'package:audiobook_app/widgets/book_cover.dart';

/// 设计规范（docs/DESIGN-SYSTEM.md）的落地护栏。
///
/// 这里锁的是三类**容易在后续改版中悄悄退化**的约定：
/// 1. 封面色由书名稳定决定（不能升级一次 App 换一次色）；
/// 2. 竖排取字必须按字素切（不能把生僻字 / emoji 切成半截）；
/// 3. 字阶只能用 400 / 500 两种字重（规范 §2 的硬约束）。

void main() {
  group('封面色板：选色必须稳定', () {
    test('同一书名永远得到同一颜色', () {
      final a = AppCoverPalette.colorFor('蛊真人');
      final b = AppCoverPalette.colorFor('蛊真人');
      expect(a, b);
    });

    test('两侧空白不影响选色', () {
      expect(
        AppCoverPalette.colorFor('  蛊真人  '),
        AppCoverPalette.colorFor('蛊真人'),
      );
    });

    test('哈希是自实现的 FNV-1a，不依赖 String.hashCode', () {
      // 期望值由独立脚本（Python 按 UTF-16 code unit 复算 FNV-1a）算出，
      // 不是手写的。若这里变了，说明选色算法被改动 —— 那会让所有老用户的
      // 封面集体换色，必须是有意为之。
      expect(AppCoverPalette.hashOf('蛊真人'), 0xb758f114);
      expect(AppCoverPalette.hashOf('诡秘之主'), 0x116eabca);
      // 空串：FNV 的 offset basis，循环不执行
      expect(AppCoverPalette.hashOf(''), 0x811c9dc5);
    });

    test('颜色一定取自色板，不会凭空生成', () {
      for (final title in ['蛊真人', '诡秘之主', '全职法师', '', '  ']) {
        expect(AppCoverPalette.colors, contains(AppCoverPalette.colorFor(title)));
      }
    });

    test('不同书名会落到不同颜色（不是永远同一个）', () {
      final picked = <Color>{
        for (final t in ['蛊真人', '诡秘之主', '全职法师', '斗破苍穹', '三体', '活着'])
          AppCoverPalette.colorFor(t),
      };
      expect(picked.length, greaterThan(1));
    });
  });

  group('竖排取字：先截主标题再切字素', () {
    test('去掉拼在标题后面的作者', () {
      expect(coverCoreTitle('蛊真人-老宝玉'), '蛊真人');
      expect(coverCoreTitle('诡秘之主·多人有声剧'), '诡秘之主');
      expect(coverCoreTitle('全职法师 | 金菲惜比'), '全职法师');
    });

    test('分隔符出现在第 2 字之前时不截断', () {
      // 'G-诡秘之主' 的分隔符在下标 1，截断会得到 'G'（几乎等于截空）
      expect(coverCoreTitle('G-诡秘之主'), 'G-诡秘之主');
      expect(coverCoreTitle('-蛊真人'), '-蛊真人');
    });

    test('最多取 4 个字', () {
      expect(coverVerticalTitle('蛊真人-老宝玉', '书'), '蛊真人');
      expect(coverVerticalTitle('诡秘之主多人有声剧', '书'), '诡秘之主');
      expect(coverVerticalTitle('活着', '书'), '活着');
    });

    test('标题为空时用兜底字', () {
      expect(coverVerticalTitle('', '书'), '书');
      expect(coverVerticalTitle('   ', '书'), '书');
    });

    test('生僻字（代理对）不会被切成乱码', () {
      // CJK 扩展 B 区字符每个都是代理对，按码元切会得到半个字符。
      const rare = '𠀋𠀌𠀍';
      final out = coverVerticalTitle(rare, '书');
      expect(out.characters.length, 3, reason: '字素被切碎了：$out');
      expect(out, rare);
    });

    test('emoji 标题同样按字素切', () {
      final out = coverVerticalTitle('🎧🎧🎧🎧🎧', '书');
      expect(out.characters.length, 4);
      expect(out, '🎧🎧🎧🎧');
    });
  });

  group('BookCover 组件', () {
    Future<void> pump(
      WidgetTester tester, {
      String title = '蛊真人',
      String? author,
      String? sourceLabel,
      double? progress,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 160,
                child: BookCover(
                  title: title,
                  author: author,
                  sourceLabel: sourceLabel,
                  progress: progress,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('无任何图片时渲染生成封面，且叠出竖排书名', (tester) async {
      await pump(tester, title: '蛊真人', author: '老宝玉');
      expect(find.text('蛊\n真\n人'), findsOneWidget);
      expect(find.text('老宝玉'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有作者时不画短横线也不报错', (tester) async {
      await pump(tester, title: '蛊真人');
      expect(find.text('蛊\n真\n人'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('给了来源才显示角标', (tester) async {
      await pump(tester, title: '蛊真人');
      expect(find.byKey(const ValueKey('book-cover-badge')), findsNothing);

      await pump(tester, title: '蛊真人', sourceLabel: '夸克');
      expect(find.byKey(const ValueKey('book-cover-badge')), findsOneWidget);
      expect(find.text('夸克'), findsOneWidget);
    });

    testWidgets('进度为 0 或未给时不画进度条', (tester) async {
      await pump(tester, progress: 0);
      expect(find.byKey(const ValueKey('book-cover-progress')), findsNothing);

      await pump(tester, progress: 0.42);
      expect(find.byKey(const ValueKey('book-cover-progress')), findsOneWidget);
    });

    testWidgets('超长书名不溢出（只排 4 字）', (tester) async {
      await pump(tester, title: '这是一本名字非常非常长的有声小说名称');
      // 竖排文本是用 \n 连接的字素，不是原串
      expect(find.text('这\n是\n一\n本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('无障碍：文字对比度必须达到 WCAG AA', () {
    // 规范 §8：正文 ≥ 4.5:1。这里把算法实现一份，避免将来改色板时
    // 悄悄退化 —— 曾经 tertiary 用 #9E9E9E，在纸白底上只有 2.56:1，
    // 而它大量用在 11px 的 micro 文本上。
    double channel(double c) =>
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();

    double luminance(Color color) {
      // 新 API 的 .r/.g/.b 已经是 0..1，不要再除以 255
      // （旧的 .red/.green/.blue 已废弃）。
      return 0.2126 * channel(color.r) +
          0.7152 * channel(color.g) +
          0.0722 * channel(color.b);
    }

    double contrast(Color a, Color b) {
      final l1 = luminance(a);
      final l2 = luminance(b);
      final hi = l1 > l2 ? l1 : l2;
      final lo = l1 > l2 ? l2 : l1;
      return (hi + 0.05) / (lo + 0.05);
    }

    Color blend(Color fg, Color bg, double alpha) {
      int mix(double a, double b) =>
          ((a * alpha + b * (1 - alpha)) * 255.0).round().clamp(0, 255).toInt();
      return Color.fromARGB(255, mix(fg.r, bg.r), mix(fg.g, bg.g),
          mix(fg.b, bg.b));
    }

    const lightBg = Color(0xFFFAFAF8);
    const darkBg = Color(0xFF141414);

    test('浅色模式三档文字色均 ≥ 4.5:1', () {
      expect(contrast(AppInk.primary(false), lightBg), greaterThanOrEqualTo(4.5));
      expect(contrast(AppInk.secondary(false), lightBg), greaterThanOrEqualTo(4.5));
      // 这一条曾经失败（#9E9E9E = 2.56:1）
      expect(contrast(AppInk.tertiary(false), lightBg), greaterThanOrEqualTo(4.5));
      expect(contrast(AppInk.accent(false), lightBg), greaterThanOrEqualTo(4.5));
    });

    test('深色模式三档文字色均 ≥ 4.5:1', () {
      expect(contrast(AppInk.primary(true), darkBg), greaterThanOrEqualTo(4.5));
      expect(contrast(AppInk.secondary(true), darkBg), greaterThanOrEqualTo(4.5));
      // 这一条曾经失败（#707070 = 3.72:1）
      expect(contrast(AppInk.tertiary(true), darkBg), greaterThanOrEqualTo(4.5));
      // 强调色在深色底上必须换成更亮的一档（同色仅 3.01:1）
      expect(contrast(AppInk.accent(true), darkBg), greaterThanOrEqualTo(4.5));
    });

    test('文字层级在两种模式下都单调（primary 最亮对比、tertiary 最低）', () {
      for (final isDark in [false, true]) {
        final bg = isDark ? darkBg : lightBg;
        final p = contrast(AppInk.primary(isDark), bg);
        final s = contrast(AppInk.secondary(isDark), bg);
        final t = contrast(AppInk.tertiary(isDark), bg);
        expect(p > s, isTrue, reason: 'isDark=$isDark primary 应强于 secondary');
        expect(s > t, isTrue, reason: 'isDark=$isDark secondary 应强于 tertiary');
      }
    });

    test('生成封面：书名与作者行在全部 8 个出版色上均 ≥ 4.5:1', () {
      const ink = AppCoverPalette.ink;
      // 与 widgets/book_cover.dart 中的实际取值保持一致
      const authorAlpha = 0.95;
      for (final bg in AppCoverPalette.colors) {
        expect(
          contrast(ink, bg),
          greaterThanOrEqualTo(4.5),
          reason: '封面色 $bg 上的书名字对比度不足',
        );
        expect(
          contrast(blend(ink, bg, authorAlpha), bg),
          greaterThanOrEqualTo(4.5),
          reason: '封面色 $bg 上的作者行对比度不足（透明度 $authorAlpha）',
        );
      }
    });
  });

  group('字阶规范：只允许 400 / 500 两种字重', () {
    test('AppType 的每一级都合规', () {
      final styles = <String, TextStyle>{
        'display': AppType.display,
        'title': AppType.title,
        'body': AppType.body,
        'caption': AppType.caption,
        'micro': AppType.micro,
      };
      styles.forEach((name, style) {
        expect(
          style.fontWeight,
          anyOf(FontWeight.w400, FontWeight.w500),
          reason: '$name 用了 ${style.fontWeight}，规范只允许 400 / 500',
        );
      });
    });

    test('字号单调递增，层级不会互相打架', () {
      expect(AppType.display.fontSize! > AppType.title.fontSize!, isTrue);
      expect(AppType.title.fontSize! > AppType.body.fontSize!, isTrue);
      expect(AppType.body.fontSize! > AppType.caption.fontSize!, isTrue);
      expect(AppType.caption.fontSize! >= AppType.micro.fontSize!, isTrue);
    });

    test('全库源码不得出现 bold / w600 及以上（规范 §2 的机器化执行）', () {
      // 只做一次代码清扫是不够的：下一个人写 `FontWeight.bold` 时没人拦得住。
      // 这条测试直接读 lib/ 源码，让规范变成可校验的约束。
      const forbidden = [
        'FontWeight.bold',
        'FontWeight.w600',
        'FontWeight.w700',
        'FontWeight.w800',
        'FontWeight.w900',
      ];
      final offenders = <String>[];
      final root = Directory('lib');
      expect(root.existsSync(), isTrue,
          reason: '测试需在工程根目录运行（找不到 lib/）');
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        for (final bad in forbidden) {
          if (text.contains(bad)) offenders.add('${entity.path} 使用了 $bad');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '规范只允许 400 / 500 两种字重，以下位置违反：\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
