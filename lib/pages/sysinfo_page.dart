import 'package:flutter/material.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/models/sysinfo_models.dart';
import 'package:aurora/services/sysinfo_session.dart';

/// 系统信息页：结构化卡片展示（参考 ServerBox 风格，按需采集）。
class SysInfoPage extends StatefulWidget {
  const SysInfoPage({super.key, required this.server});

  final Server server;

  @override
  State<SysInfoPage> createState() => _SysInfoPageState();
}

class _SysInfoPageState extends State<SysInfoPage> {
  late final SysInfoSession _session;
  SysInfoTab _tab = SysInfoTab.basic;
  bool _connecting = true;
  String? _pageError;

  static const _tabs = SysInfoTab.values;

  static IconData _icon(SysInfoTab t) => switch (t) {
        SysInfoTab.basic => Icons.info_outline,
        SysInfoTab.process => Icons.memory,
        SysInfoTab.service => Icons.settings_applications_outlined,
        SysInfoTab.firewall => Icons.security_outlined,
        SysInfoTab.power => Icons.power_settings_new,
        SysInfoTab.users => Icons.people_outline,
        SysInfoTab.cron => Icons.schedule,
        SysInfoTab.docker => Icons.view_in_ar_outlined,
      };

  @override
  void initState() {
    super.initState();
    _session = SysInfoSession(server: widget.server);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _connecting = true;
      _pageError = null;
    });
    try {
      await _session.connect();
      if (!mounted) return;
      setState(() => _connecting = false);
      await _loadTab(_tab);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _pageError = e.toString();
      });
    }
  }

  Future<void> _loadTab(SysInfoTab tab, {bool force = false}) async {
    if (!_session.connected) {
      await _bootstrap();
      return;
    }
    setState(() {});
    try {
      await _session.fetch(tab, force: force);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _onTabSelected(int index) {
    final tab = _tabs[index];
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (!_session.loaded.contains(tab)) {
      _loadTab(tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.server.name, style: const TextStyle(fontSize: 16)),
            Text(
              '${widget.server.displayAddr} · ${_tab.label}',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _connecting || _session.loading.contains(_tab)
                ? null
                : () => _loadTab(_tab, force: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(scheme),
      bottomNavigationBar: Material(
        elevation: 3,
        color: scheme.surfaceContainer,
        child: SafeArea(
          child: SizedBox(
            height: 64,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _tabs.length,
              itemBuilder: (context, i) {
                final t = _tabs[i];
                final selected = t == _tab;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _onTabSelected(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.secondaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _icon(t),
                            size: 22,
                            color: selected
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pageError != null) {
      return _ErrorPane(
        message: _pageError!,
        onRetry: _bootstrap,
      );
    }

    final loading = _session.loading.contains(_tab);
    final err = _session.errors[_tab];
    final hasData = _session.loaded.contains(_tab);

    if (loading && !hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (err != null && !hasData) {
      return _ErrorPane(
        message: err,
        onRetry: () => _loadTab(_tab, force: true),
      );
    }

    return Column(
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildTabContent(scheme)),
      ],
    );
  }

  Widget _buildTabContent(ColorScheme scheme) {
    return switch (_tab) {
      SysInfoTab.basic => _BasicView(info: _session.basic),
      SysInfoTab.process => _ProcessView(list: _session.processes ?? const []),
      SysInfoTab.service => _ServiceView(
          running: _session.services ?? const [],
          failed: _session.failedServices ?? const [],
        ),
      SysInfoTab.firewall => _FirewallView(info: _session.firewall),
      SysInfoTab.power => _PowerView(info: _session.power),
      SysInfoTab.users => _UsersView(list: _session.users ?? const []),
      SysInfoTab.cron => _CronView(list: _session.cron ?? const []),
      SysInfoTab.docker => _DockerView(info: _session.docker),
    };
  }
}

// ═══════════════════════════════════════════════════════════
// 公共小组件
// ═══════════════════════════════════════════════════════════

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              k,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              v.isEmpty ? '—' : v,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.ratio,
    required this.label,
    this.sub,
  });

  final double ratio;
  final String label;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = ratio.clamp(0.0, 1.0);
    final color = r > 0.9
        ? scheme.error
        : r > 0.75
            ? Colors.orange
            : scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            Text(
              '${(r * 100).toStringAsFixed(0)}%'
              '${sub != null ? ' · $sub' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: r,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _ChipStat extends StatelessWidget {
  const _ChipStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
              )),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: scheme.onPrimaryContainer.withValues(alpha: 0.8))),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.ok, this.label});
  final bool ok;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = ok ? Colors.green : Colors.redAccent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        if (label != null) ...[
          const SizedBox(width: 6),
          Text(label!, style: TextStyle(fontSize: 12, color: c)),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 基础
// ═══════════════════════════════════════════════════════════

class _BasicView extends StatelessWidget {
  const _BasicView({this.info});
  final BasicInfo? info;

  @override
  Widget build(BuildContext context) {
    if (info == null) {
      return const Center(child: Text('暂无数据'));
    }
    final b = info!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _SectionCard(
          title: '主机',
          icon: Icons.dns_outlined,
          child: Column(
            children: [
              _Kv('主机名', b.hostname),
              _Kv('系统', b.osPretty),
              _Kv('内核', b.kernel),
              _Kv('运行', b.uptimeText),
            ],
          ),
        ),
        if (b.load1 != null || b.cpuModel.isNotEmpty)
          _SectionCard(
            title: 'CPU / 负载',
            icon: Icons.developer_board_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (b.cpuModel.isNotEmpty) _Kv('型号', b.cpuModel),
                if (b.cpuCores != null) _Kv('核心', '${b.cpuCores}'),
                const SizedBox(height: 8),
                if (b.load1 != null)
                  Row(
                    children: [
                      Expanded(
                          child: _ChipStat(
                              label: '1 分钟',
                              value: b.load1!.toStringAsFixed(2))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _ChipStat(
                              label: '5 分钟',
                              value: (b.load5 ?? 0).toStringAsFixed(2))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _ChipStat(
                              label: '15 分钟',
                              value: (b.load15 ?? 0).toStringAsFixed(2))),
                    ],
                  ),
              ],
            ),
          ),
        if (b.mem != null)
          _SectionCard(
            title: '内存',
            icon: Icons.memory_outlined,
            child: Column(
              children: [
                _UsageBar(
                  ratio: b.mem!.usedRatio,
                  label: '内存',
                  sub: '${b.mem!.usedLabel} / ${b.mem!.totalLabel}',
                ),
                if (b.mem!.swapTotalKb != null && b.mem!.swapTotalKb! > 0) ...[
                  const SizedBox(height: 12),
                  _UsageBar(
                    ratio: (b.mem!.swapUsedKb ?? 0) / b.mem!.swapTotalKb!,
                    label: 'Swap',
                    sub:
                        '${_fmtKb(b.mem!.swapUsedKb ?? 0)} / ${_fmtKb(b.mem!.swapTotalKb!)}',
                  ),
                ],
              ],
            ),
          ),
        if (b.disks.isNotEmpty)
          _SectionCard(
            title: '磁盘',
            icon: Icons.storage_outlined,
            child: Column(
              children: [
                for (var i = 0; i < b.disks.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _UsageBar(
                    ratio: (b.disks[i].usedPercent ?? 0) / 100.0,
                    label: b.disks[i].mount,
                    sub:
                        '${b.disks[i].used} / ${b.disks[i].size} · ${b.disks[i].filesystem}',
                  ),
                ],
              ],
            ),
          ),
        if (b.ifaces.isNotEmpty)
          _SectionCard(
            title: '网络',
            icon: Icons.lan_outlined,
            child: Column(
              children: [
                for (final n in b.ifaces)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.cable,
                      color: n.state.toUpperCase().contains('UP')
                          ? Colors.green
                          : Theme.of(context).colorScheme.outline,
                    ),
                    title: Text(n.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      [
                        if (n.state.isNotEmpty) n.state,
                        if (n.addrs.isNotEmpty) n.addrs,
                      ].join(' · '),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String _fmtKb(int kb) {
    if (kb < 1024) return '$kb KB';
    if (kb < 1024 * 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
    return '${(kb / (1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

// ═══════════════════════════════════════════════════════════
// 进程
// ═══════════════════════════════════════════════════════════

class _ProcessView extends StatelessWidget {
  const _ProcessView({required this.list});
  final List<ProcessInfo> list;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return const Center(child: Text('无进程数据'));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final p = list[i];
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              p.pid.length > 4 ? p.pid.substring(0, 4) : p.pid,
              style: TextStyle(
                  fontSize: 10, color: scheme.onPrimaryContainer),
            ),
          ),
          title: Text(
            p.command.isEmpty ? '(unknown)' : p.command,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            [
              if (p.user.isNotEmpty) p.user,
              'PID ${p.pid}',
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (p.cpu != null)
                Text('CPU ${p.cpu!.toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12)),
              if (p.mem != null)
                Text('MEM ${p.mem!.toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 服务
// ═══════════════════════════════════════════════════════════

class _ServiceView extends StatelessWidget {
  const _ServiceView({required this.running, required this.failed});
  final List<ServiceInfo> running;
  final List<ServiceInfo> failed;

  @override
  Widget build(BuildContext context) {
    if (running.isEmpty && failed.isEmpty) {
      return const Center(child: Text('无服务数据'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (failed.isNotEmpty)
          _SectionCard(
            title: '失败 (${failed.length})',
            icon: Icons.error_outline,
            child: Column(
              children: [
                for (final s in failed) _serviceTile(context, s, failed: true),
              ],
            ),
          ),
        _SectionCard(
          title: running.any((e) => e.active == 'init.d')
              ? 'init.d / 服务 (${running.length})'
              : '运行中 (${running.length})',
          icon: Icons.check_circle_outline,
          child: Column(
            children: [
              for (final s in running) _serviceTile(context, s),
            ],
          ),
        ),
      ],
    );
  }

  Widget _serviceTile(BuildContext context, ServiceInfo s,
      {bool failed = false}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: _StatusDot(ok: !failed && s.isRunning),
      title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          if (s.sub.isNotEmpty) s.sub,
          if (s.description.isNotEmpty) s.description,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: failed
          ? Chip(
              label: const Text('failed', style: TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              backgroundColor: scheme.errorContainer,
            )
          : (s.active.isNotEmpty
              ? Text(s.active,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant))
              : null),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 防火墙
// ═══════════════════════════════════════════════════════════

class _FirewallView extends StatelessWidget {
  const _FirewallView({this.info});
  final FirewallInfo? info;

  @override
  Widget build(BuildContext context) {
    if (info == null) return const Center(child: Text('暂无数据'));
    final f = info!;
    if (f.highlights.isEmpty) {
      return Center(child: Text(f.summary));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _SectionCard(
          title: '概览',
          icon: Icons.security_outlined,
          child: Text(f.summary),
        ),
        for (final block in f.highlights)
          _SectionCard(
            title: block.split('\n').first,
            icon: Icons.rule,
            child: SelectableText(
              block.contains('\n')
                  ? block.substring(block.indexOf('\n') + 1)
                  : block,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12, height: 1.35),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 电源
// ═══════════════════════════════════════════════════════════

class _PowerView extends StatelessWidget {
  const _PowerView({this.info});
  final PowerInfo? info;

  @override
  Widget build(BuildContext context) {
    if (info == null) return const Center(child: Text('暂无数据'));
    final p = info!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _SectionCard(
          title: '运行状态',
          icon: Icons.timelapse,
          child: Column(
            children: [
              _Kv('运行时间', p.uptimeText),
              if (p.bootTime.isNotEmpty) _Kv('启动', p.bootTime),
            ],
          ),
        ),
        if (p.batteries.isNotEmpty)
          _SectionCard(
            title: '电源 / 电池',
            icon: Icons.battery_charging_full,
            child: Column(
              children: [
                for (final b in p.batteries) ...[
                  _Kv(b.name, '${b.type} · ${b.status}'),
                  if (b.capacity != null) ...[
                    const SizedBox(height: 6),
                    _UsageBar(
                      ratio: b.capacity! / 100.0,
                      label: '电量',
                      sub: '${b.capacity}%',
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ],
            ),
          ),
        if (p.temps.isNotEmpty)
          _SectionCard(
            title: '温度',
            icon: Icons.thermostat_outlined,
            child: Column(
              children: [
                for (final t in p.temps) _Kv('传感器', t),
              ],
            ),
          ),
        if (p.recentEvents.isNotEmpty)
          _SectionCard(
            title: '最近事件',
            icon: Icons.history,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in p.recentEvents)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(e, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 用户
// ═══════════════════════════════════════════════════════════

class _UsersView extends StatelessWidget {
  const _UsersView({required this.list});
  final List<UserInfo> list;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return const Center(child: Text('无用户数据'));
    final scheme = Theme.of(context).colorScheme;
    final loginShell = list
        .where((u) =>
            u.shell.contains('sh') &&
            !u.shell.contains('nologin') &&
            !u.shell.contains('false'))
        .toList();
    final show = loginShell.isNotEmpty ? loginShell : list;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: show.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final u = show[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: u.loggedIn
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            child: Icon(
              Icons.person_outline,
              color: u.loggedIn
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
          title: Row(
            children: [
              Text(u.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (u.loggedIn) ...[
                const SizedBox(width: 8),
                const _StatusDot(ok: true, label: '在线'),
              ],
            ],
          ),
          subtitle: Text(
            'uid ${u.uid} · ${u.home}\n${u.shell}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          isThreeLine: true,
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
// 计划任务
// ═══════════════════════════════════════════════════════════

class _CronView extends StatelessWidget {
  const _CronView({required this.list});
  final List<CronEntry> list;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return const Center(child: Text('未发现计划任务'));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[i];
        return Card(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          margin: const EdgeInsets.only(bottom: 8),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            title: Text(
              c.command,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              [
                if (c.schedule.isNotEmpty) c.schedule,
                c.source,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            leading: Icon(Icons.alarm, color: scheme.primary),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════
// Docker
// ═══════════════════════════════════════════════════════════

class _DockerView extends StatelessWidget {
  const _DockerView({this.info});
  final DockerInfo? info;

  @override
  Widget build(BuildContext context) {
    if (info == null) return const Center(child: Text('暂无数据'));
    final d = info!;
    if (!d.available) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(d.errorHint ?? 'Docker 不可用', textAlign: TextAlign.center),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _SectionCard(
          title: 'Docker',
          icon: Icons.view_in_ar_outlined,
          child: Text(d.versionLine),
        ),
        _SectionCard(
          title: '容器 (${d.containers.length})',
          icon: Icons.widgets_outlined,
          child: d.containers.isEmpty
              ? const Text('无容器')
              : Column(
                  children: [
                    for (final c in d.containers)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: _StatusDot(ok: c.isUp),
                        title: Text(c.names.isEmpty ? c.id : c.names,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          [
                            c.image,
                            c.status,
                            if (c.ports.isNotEmpty) c.ports,
                          ].join('\n'),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        isThreeLine: true,
                      ),
                  ],
                ),
        ),
        if (d.images.isNotEmpty)
          _SectionCard(
            title: '镜像 (${d.images.length})',
            icon: Icons.layers_outlined,
            child: Column(
              children: [
                for (final img in d.images)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      '${img.repository}:${img.tag}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text('${img.id} · ${img.size}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
