import 'package:flutter/material.dart';
import 'package:aurora/pages/virt_keys_settings_page.dart';
import 'package:aurora/services/settings_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = SettingsStore.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('外观'),
          ListTile(
            title: const Text('主题'),
            subtitle: Text(switch (_settings.themeMode) {
              AppThemeMode.system => '跟随系统',
              AppThemeMode.light => '浅色',
              AppThemeMode.dark => '深色',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTheme(context),
          ),
          ListTile(
            title: const Text('终端字号'),
            subtitle: Text('${_settings.fontSize.toStringAsFixed(0)}'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                value: _settings.fontSize,
                min: 10,
                max: 22,
                divisions: 12,
                label: _settings.fontSize.toStringAsFixed(0),
                onChanged: (v) => _settings.setFontSize(v),
              ),
            ),
          ),
          const Divider(),
          const _SectionHeader('终端'),
          SwitchListTile(
            title: const Text('启用本机终端'),
            subtitle: const Text('首页显示本机 shell 入口（不支持 SFTP）'),
            value: _settings.enableLocalTerminal,
            onChanged: (v) => _settings.setEnableLocalTerminal(v),
          ),
          SwitchListTile(
            title: const Text('终端退出确认'),
            subtitle: const Text('SSH 连接中返回时弹出确认（本机终端始终不弹）'),
            value: _settings.confirmExitTerminal,
            onChanged: (v) => _settings.setConfirmExitTerminal(v),
          ),
          SwitchListTile(
            title: const Text('显示虚拟按键'),
            subtitle: const Text('底部 Ctrl / Esc / 方向键等'),
            value: _settings.showVirtKeys,
            onChanged: (v) => _settings.setShowVirtKeys(v),
          ),
          SwitchListTile(
            title: const Text('修饰键自动取消'),
            subtitle: const Text('Ctrl 等组合生效一次后自动熄灭'),
            value: _settings.virtKeyAutoOff,
            onChanged: (v) => _settings.setVirtKeyAutoOff(v),
          ),
          ListTile(
            title: const Text('自定义虚拟按键'),
            subtitle: Text(
              '已选 ${_settings.virtKeyIds.length} 键 · 每行 ${_settings.virtKeysPerRow}',
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: _settings.showVirtKeys,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const VirtKeysSettingsPage(),
                ),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('关于'),
          const ListTile(
            title: Text('Aurora'),
            subtitle: Text('v1.0.0 · xterm + dartssh2'),
          ),
          const ListTile(
            title: Text('说明'),
            subtitle: Text(
              '轻量 SSH 客户端。服务器信息保存在本地，不会上传。',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTheme(BuildContext context) async {
    final selected = await showModalBottomSheet<AppThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in AppThemeMode.values)
              ListTile(
                title: Text(switch (mode) {
                  AppThemeMode.system => '跟随系统',
                  AppThemeMode.light => '浅色',
                  AppThemeMode.dark => '深色',
                }),
                trailing: _settings.themeMode == mode
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, mode),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await _settings.setThemeMode(selected);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
