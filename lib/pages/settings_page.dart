import 'package:flutter/material.dart';
import 'package:aurora/pages/virt_keys_settings_page.dart';
import 'package:aurora/services/linux_env.dart';
import 'package:aurora/services/settings_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = SettingsStore.instance;
  final _linux = LinuxEnv.instance;

  /// rootfs 占用（字节），按需计算一次。
  int? _linuxSize;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _linux.stateNotifier.addListener(_onLinuxChanged);
    _linux.progressNotifier.addListener(_onLinuxChanged);
    _linux.messageNotifier.addListener(_onLinuxChanged);
    _linux.refresh();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _linux.stateNotifier.removeListener(_onLinuxChanged);
    _linux.progressNotifier.removeListener(_onLinuxChanged);
    _linux.messageNotifier.removeListener(_onLinuxChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onLinuxChanged() {
    if (!mounted) return;
    setState(() {});
    if (_linux.state == LinuxEnvState.ready && _linuxSize == null) {
      _loadSize();
    }
  }

  Future<void> _loadSize() async {
    final size = await _linux.sizeBytes();
    if (!mounted) return;
    setState(() => _linuxSize = size);
  }

  /// 删除 rootfs 后重新部署。
  Future<void> _redeploy() async {
    setState(() => _linuxSize = null);
    await _linux.uninstall();
    await _linux.install();
  }

  /// Alpine 部署状态行（仅在开关打开时显示）。
  Widget _linuxStatusTile() {
    final state = _linux.state;
    final busy = state == LinuxEnvState.downloading ||
        state == LinuxEnvState.extracting;

    final subtitle = switch (state) {
      LinuxEnvState.ready =>
        '已部署${_linuxSize != null ? ' · 占用 ${_sizeMb(_linuxSize!)} MB' : ''}',
      LinuxEnvState.failed => _linux.error ?? '部署失败',
      LinuxEnvState.missing => '未部署',
      LinuxEnvState.unknown => '检查中…',
      _ => _linux.message.isEmpty
          ? state.label
          : '${state.label}：${_linux.message}',
    };

    return Column(
      children: [
        ListTile(
          title: const Text('Alpine 环境'),
          subtitle: Text(subtitle),
          trailing: busy
              ? Text('${(_linux.progress * 100).toInt()}%')
              : PopupMenuButton<String>(
                  tooltip: '更多操作',
                  onSelected: (v) {
                    if (v == 'redeploy') _redeploy();
                    if (v == 'clean') _linux.uninstall();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'redeploy', child: Text('重新部署')),
                    PopupMenuItem(value: 'clean', child: Text('清理 rootfs')),
                  ],
                ),
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: _linux.progress <= 0 ? null : _linux.progress,
            ),
          ),
      ],
    );
  }

  static String _sizeMb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(0);

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
            title: const Text('启用 Linux 终端'),
            subtitle: const Text('首页显示 Linux 入口：本机 proot 运行 Alpine 3.22.5'),
            value: _settings.enableLinuxTerminal,
            onChanged: (v) => _settings.setEnableLinuxTerminal(v),
          ),
          if (_settings.enableLinuxTerminal) _linuxStatusTile(),
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
