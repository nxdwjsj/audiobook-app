import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../repositories/book_source_repository.dart';
import '../services/book_source/book_source.dart';
import '../widgets/frosted_glass.dart';

/// 书源管理：列表 / 开关 / 导入 / 导出 / 恢复内置。
///
/// 入口在全网搜书页 AppBar 的源图标按钮。
class BookSourcePage extends StatefulWidget {
  const BookSourcePage({super.key});

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  @override
  Widget build(BuildContext context) {
    final repo = context.watch<BookSourceRepository>();
    final sources = repo.all;
    final enabledCount = repo.enabled.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('书源管理（${sources.length} 个，启用 $enabledCount）'),
      ),
      body: sources.isEmpty
          ? const Center(child: Text('没有书源，点右上角导入'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: sources.length,
              itemBuilder: (context, i) =>
                  _SourceTile(source: sources[i]),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _import,
        icon: const Icon(Icons.add_rounded),
        label: const Text('导入书源'),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 导入
  // ------------------------------------------------------------------

  Future<void> _import() async {
    final controller = TextEditingController();
    final ok = await showFrostedBottomSheet<bool>(
      context: context,
      // 键盘弹起时内容可顶起
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('导入书源',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '粘贴书源 JSON（支持单个对象或数组）',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '{"id": "...", "name": "...", "url": "..."}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('导入'),
              ),
            ],
          ),
        );
      },
    );
    final text = ok == true ? controller.text : null;
    // 退场动画结束后再释放，避免动画期访问已 dispose 的 controller
    Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (text == null || text.trim().isEmpty) return;
    if (!mounted) return;

    final repo = context.read<BookSourceRepository>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (added, errors) = await repo.importFromText(text);
      if (!mounted) return;
      if (added.isNotEmpty) {
        messenger.showSnackBar(SnackBar(
            content: Text(
                '已导入 ${added.length} 个书源${errors.isNotEmpty ? '，${errors.length} 条失败' : ''}')));
      } else if (errors.isNotEmpty) {
        messenger.showSnackBar(
            SnackBar(content: Text('导入失败：${errors.first}')));
      }
    } on FormatException catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导入失败：${e.message}')));
      }
    }
  }
}

/// 单个书源条目：开关 + 名称/host + 菜单（导出 / 重置 / 删除）。
class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source});

  final BookSource source;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<BookSourceRepository>();
    final isBuiltin = repo.isBuiltin(source);
    final enabled = repo.isEnabled(source);
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(
        Icons.travel_explore_rounded,
        color: enabled ? theme.colorScheme.primary : theme.disabledColor,
      ),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${source.host}${isBuiltin ? ' · 内置' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: enabled,
            onChanged: (v) => repo.setEnabled(source, v),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onSelected: (action) => _onMenu(context, action),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'export',
                child: Text('复制 JSON（分享给别人）'),
              ),
              if (isBuiltin)
                const PopupMenuItem(
                  value: 'reset',
                  child: Text('恢复内置规则'),
                )
              else
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, String action) async {
    final repo = context.read<BookSourceRepository>();
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'export':
        await Clipboard.setData(
            ClipboardData(text: repo.exportSource(source)));
        messenger.showSnackBar(
            SnackBar(content: Text('「${source.name}」的 JSON 已复制')));
        break;
      case 'reset':
        await repo.resetBuiltin(source.id);
        messenger.showSnackBar(
            SnackBar(content: Text('「${source.name}」已恢复内置规则')));
        break;
      case 'delete':
        final ok = await repo.remove(source.id);
        if (!ok) {
          messenger.showSnackBar(
              const SnackBar(content: Text('内置书源不能删除，只能关闭')));
        }
        break;
    }
  }
}
