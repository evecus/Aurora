import 'package:flutter/material.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/pages/server_edit_page.dart';
import 'package:aurora/pages/settings_page.dart';
import 'package:aurora/pages/sftp_page.dart';
import 'package:aurora/pages/sysinfo_page.dart';
import 'package:aurora/pages/terminal_page.dart';
import 'package:aurora/services/server_store.dart';
import 'package:aurora/services/settings_store.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = ServerStore.instance;
  final _settings = SettingsStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _settings.addListener(_onChanged);
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 合并「本机 + 服务器」并按 [SettingsStore.homeListOrder] 排序。
  List<Server> _orderedItems() {
    final servers = _store.servers;
    final showLocal = _settings.enableLocalTerminal;
    final byId = {for (final s in servers) s.id: s};
    if (showLocal) {
      byId[Server.localId] = Server.local;
    }

    final ordered = <Server>[];
    final seen = <String>{};
    for (final id in _settings.homeListOrder) {
      final s = byId[id];
      if (s == null) continue;
      // 本机关闭时跳过 local
      if (id == Server.localId && !showLocal) continue;
      ordered.add(s);
      seen.add(id);
    }
    // 新服务器或首次启用本机：追加到末尾（本机默认插到最前）
    if (showLocal && !seen.contains(Server.localId)) {
      ordered.insert(0, Server.local);
      seen.add(Server.localId);
    }
    for (final s in servers) {
      if (!seen.contains(s.id)) ordered.add(s);
    }
    return ordered;
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final items = _orderedItems();
    if (oldIndex < 0 || oldIndex >= items.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= items.length) return;
    final moved = items.removeAt(oldIndex);
    items.insert(newIndex, moved);
    await _settings.setHomeListOrder(items.map((e) => e.id).toList());
  }

  Future<void> _openTerminal(Server server) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalPage(server: server),
      ),
    );
  }

  Future<void> _openSftp(Server server) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpPage(server: server),
      ),
    );
  }

  Future<void> _openSysInfo(Server server) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SysInfoPage(server: server),
      ),
    );
  }

  Future<void> _addServer() async {
    await Navigator.of(context).push<Server>(
      MaterialPageRoute(builder: (_) => const ServerEditPage()),
    );
  }

  Future<void> _editServer(Server server) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServerEditPage(server: server),
      ),
    );
  }

  Future<void> _deleteServer(Server server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定删除「${server.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.remove(server.id);
      // 同步从排序里去掉
      final order = List<String>.of(_settings.homeListOrder)
        ..remove(server.id);
      if (order.length != _settings.homeListOrder.length) {
        await _settings.setHomeListOrder(order);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _orderedItems();
    final scheme = Theme.of(context).colorScheme;
    final isEmpty = items.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器'),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns_outlined, size: 72, color: scheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    '还没有服务器',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击右下角添加一台，或在设置中启用本机终端',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
                ],
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              itemCount: items.length,
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) {
                    final t = Curves.easeInOut.transform(animation.value);
                    return Material(
                      elevation: 2 + 4 * t,
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: child,
                    );
                  },
                  child: child,
                );
              },
              onReorder: (oldIndex, newIndex) {
                _onReorder(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final s = items[index];
                final isLocal = s.isLocal;
                return Padding(
                  key: ValueKey(s.id),
                  padding: EdgeInsets.only(bottom: index == items.length - 1 ? 0 : 8),
                  child: ReorderableDelayedDragStartListener(
                    index: index,
                    child: _ServerTile(
                      server: s,
                      isLocal: isLocal,
                      onTap: () => _openTerminal(s),
                      onSftp: isLocal ? null : () => _openSftp(s),
                      onSysInfo: isLocal ? null : () => _openSysInfo(s),
                      onEdit: isLocal ? null : () => _editServer(s),
                      onDelete: isLocal ? null : () => _deleteServer(s),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.isLocal,
    required this.onTap,
    this.onSftp,
    this.onSysInfo,
    this.onEdit,
    this.onDelete,
  });

  final Server server;
  final bool isLocal;
  final VoidCallback onTap;
  final VoidCallback? onSftp;
  final VoidCallback? onSysInfo;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        // 长按留给拖动排序，不再用长按打开编辑
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isLocal
                      ? scheme.tertiaryContainer
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isLocal ? Icons.phone_android : Icons.terminal,
                  color: isLocal
                      ? scheme.onTertiaryContainer
                      : scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isLocal
                          ? '本地 shell · 本机'
                          : '${server.username}@${server.displayAddr}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (!isLocal) ...[
                IconButton(
                  tooltip: '系统信息',
                  icon: Icon(Icons.monitor_heart_outlined, color: scheme.primary),
                  onPressed: onSysInfo,
                ),
                IconButton(
                  tooltip: 'SFTP 文件',
                  icon: Icon(Icons.folder_outlined, color: scheme.primary),
                  onPressed: onSftp,
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'sysinfo') onSysInfo?.call();
                    if (v == 'sftp') onSftp?.call();
                    if (v == 'edit') onEdit?.call();
                    if (v == 'delete') onDelete?.call();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'sysinfo', child: Text('系统信息')),
                    PopupMenuItem(value: 'sftp', child: Text('SFTP 文件')),
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
