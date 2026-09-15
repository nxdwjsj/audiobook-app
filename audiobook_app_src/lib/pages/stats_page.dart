import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../repositories/stats_repository.dart';
import '../widgets/frosted_glass.dart';

/// 收听统计页：月度方格热力图（方格颜色越深 = 当天听得越久，
/// 空白 = 当天没听）+ 累计总时长 + 单本时长排行。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// 当前展示的月份（指向该月 1 号）。
  late DateTime _month;

  static const List<String> _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<StatsRepository>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('收听统计')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _buildHeatmapCard(context, stats),
          const SizedBox(height: 16),
          _buildTotalCard(context, stats),
          const SizedBox(height: 16),
          _buildBookSection(context, stats),
        ],
      ),
    );
  }

  // --- 月度热力图 ---

  Widget _buildHeatmapCard(BuildContext context, StatsRepository stats) {
    final scheme = Theme.of(context).colorScheme;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = DateTime(_month.year, _month.month, 1).weekday - 1; // 周一为首列
    final monthSeconds = List.generate(
      daysInMonth,
      (i) => stats.secondsOn(DateTime(_month.year, _month.month, i + 1)),
    ).fold(0, (a, b) => a + b);

    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                  tooltip: '上个月',
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${_month.year} 年 ${_month.month} 月',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '本月共听 ${_formatDuration(monthSeconds)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _isCurrentMonth ? null : () => _shiftMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                  tooltip: '下个月',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final label in _weekdayLabels)
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 4.0;
                final cell = (constraints.maxWidth - gap * 6) / 7;
                final total = leading + daysInMonth;
                final rows = (total / 7).ceil();
                return Column(
                  children: [
                    for (var row = 0; row < rows; row++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: gap),
                        child: Row(
                          children: [
                            for (var col = 0; col < 7; col++)
                              Padding(
                                padding: EdgeInsets.only(
                                    right: col == 6 ? 0 : gap),
                                child: _buildCell(
                                  context,
                                  index: row * 7 + col - leading,
                                  daysInMonth: daysInMonth,
                                  size: cell,
                                  stats: stats,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            _buildLegend(context, scheme),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context, {
    required int index,
    required int daysInMonth,
    required double size,
    required StatsRepository stats,
  }) {
    if (index < 0 || index >= daysInMonth) {
      return SizedBox(width: size, height: size);
    }
    final day = index + 1;
    final daySeconds = stats.secondsOn(DateTime(_month.year, _month.month, day));
    final scheme = Theme.of(context).colorScheme;
    final bg = _levelColor(scheme, daySeconds);
    final level = _levelOf(daySeconds);
    final now = DateTime.now();
    final isToday = now.year == _month.year &&
        now.month == _month.month &&
        now.day == day;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: isToday ? Border.all(color: scheme.primary, width: 1.6) : null,
      ),
      child: Text(
        '$day',
        style: TextStyle(
          fontSize: size * 0.32,
          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
          color: level >= 3 ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 时长 → 深浅档位（0 表示当天没听）。
  int _levelOf(int seconds) {
    if (seconds <= 0) return 0;
    final minutes = seconds / 60;
    if (minutes < 20) return 1;
    if (minutes < 45) return 2;
    if (minutes < 90) return 3;
    if (minutes < 180) return 4;
    return 5;
  }

  Color _levelColor(ColorScheme scheme, int seconds) {
    final level = _levelOf(seconds);
    if (level == 0) return scheme.surfaceContainerHighest;
    const alphas = [0.0, 0.28, 0.48, 0.68, 0.84, 1.0];
    return scheme.primary.withValues(alpha: alphas[level]);
  }

  Widget _buildLegend(BuildContext context, ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '少',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 4),
        for (var level = 0; level <= 5; level++)
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: level == 0
                  ? scheme.surfaceContainerHighest
                  : scheme.primary.withValues(alpha: const [0.0, 0.28, 0.48, 0.68, 0.84, 1.0][level]),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 2),
        Text(
          '多',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // --- 累计总时长 ---

  Widget _buildTotalCard(BuildContext context, StatsRepository stats) {
    final scheme = Theme.of(context).colorScheme;
    final total = stats.totalSeconds;
    final listenedDays = stats.listenedDays;

    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(Icons.headphones_rounded, size: 36, color: scheme.primary),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '累计收听',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatDuration(total),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (listenedDays > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '有收听记录 $listenedDays 天',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- 单本时长 ---

  Widget _buildBookSection(BuildContext context, StatsRepository stats) {
    final scheme = Theme.of(context).colorScheme;
    final books = stats.bookStats.where((b) => b.seconds > 0).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '各书收听时长',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (books.isEmpty)
          GlassSurface(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  '还没有收听记录，去播放一本书吧',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          )
        else
          GlassSurface(
            child: Column(
              children: [
                for (var i = 0; i < books.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildBookTile(context, books[i], books.first.seconds, scheme),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBookTile(
    BuildContext context,
    BookListenStat stat,
    int maxSeconds,
    ColorScheme scheme,
  ) {
    final ratio = maxSeconds > 0 ? stat.seconds / maxSeconds : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDuration(stat.seconds),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(int seconds) {
    if (seconds <= 0) return '0 分钟';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m > 0 ? '$h 小时 $m 分' : '$h 小时';
    if (m > 0) return '$m 分钟';
    return '$seconds 秒';
  }
}