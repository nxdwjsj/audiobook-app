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
  });
}
