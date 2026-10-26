import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/models/sysinfo_models.dart';

enum SysInfoTab {
  basic,
  process,
  service,
  firewall,
  power,
  users,
  cron,
  docker,
}

extension SysInfoTabX on SysInfoTab {
  String get label => switch (this) {
        SysInfoTab.basic => '基础',
        SysInfoTab.process => '进程',
        SysInfoTab.service => '服务',
        SysInfoTab.firewall => '防火墙',
        SysInfoTab.power => '电源',
        SysInfoTab.users => '用户',
        SysInfoTab.cron => '计划',
        SysInfoTab.docker => 'Docker',
      };
}

/// 按需采集 + 解析为结构化模型（进入 Tab 时才跑命令）。
class SysInfoSession {
  SysInfoSession({required this.server});

  final Server server;

  SSHClient? _client;
  bool connected = false;
  String? connectError;

  BasicInfo? basic;
  List<ProcessInfo>? processes;
  List<ServiceInfo>? services;
  List<ServiceInfo>? failedServices;
  FirewallInfo? firewall;
  PowerInfo? power;
  List<UserInfo>? users;
  List<CronEntry>? cron;
  DockerInfo? docker;

  final Set<SysInfoTab> loaded = {};
  final Set<SysInfoTab> loading = {};
  final Map<SysInfoTab, String?> errors = {};

  Future<void> connect() async {
    if (connected && _client != null) return;
    connectError = null;
    try {
      final socket = await SSHSocket.connect(
        server.host,
        server.port,
        timeout: const Duration(seconds: 15),
      );
      List<SSHKeyPair> identities = const [];
      if (server.privateKey != null && server.privateKey!.trim().isNotEmpty) {
        identities = SSHKeyPair.fromPem(
          server.privateKey!,
          server.passphrase,
        );
      }
      _client = SSHClient(
        socket,
        username: server.username,
        onPasswordRequest: (server.password != null &&
                server.password!.isNotEmpty)
            ? () => server.password!
            : null,
        identities: identities,
      );
      await _client!.authenticated;
      connected = true;
    } catch (e, st) {
      debugPrint('SysInfo connect failed: $e\n$st');
      connectError = e.toString();
      connected = false;
      await close();
      rethrow;
    }
  }

  Future<void> fetch(SysInfoTab tab, {bool force = false}) async {
    if (!force && loaded.contains(tab) && errors[tab] == null) return;
    if (_client == null || !connected) await connect();
    loading.add(tab);
    errors[tab] = null;
    try {
      switch (tab) {
        case SysInfoTab.basic:
          basic = await _fetchBasic();
        case SysInfoTab.process:
          processes = await _fetchProcesses();
        case SysInfoTab.service:
          final r = await _fetchServices();
          services = r.$1;
          failedServices = r.$2;
        case SysInfoTab.firewall:
          firewall = await _fetchFirewall();
        case SysInfoTab.power:
          power = await _fetchPower();
        case SysInfoTab.users:
          users = await _fetchUsers();
        case SysInfoTab.cron:
          cron = await _fetchCron();
        case SysInfoTab.docker:
          docker = await _fetchDocker();
      }
      loaded.add(tab);
    } catch (e, st) {
      debugPrint('SysInfo fetch $tab: $e\n$st');
      errors[tab] = e.toString();
      rethrow;
    } finally {
      loading.remove(tab);
    }
  }

  Future<String> _run(String cmd) async {
    final raw = await _client!.run(cmd);
    return utf8.decode(raw, allowMalformed: true);
  }

  Future<BasicInfo> _fetchBasic() async {
    final out = await _run(r'''
printf '@@HOST@@\n'
hostname 2>/dev/null
printf '@@KERNEL@@\n'
uname -r 2>/dev/null
uname -m 2>/dev/null
printf '@@OS@@\n'
(grep -E '^(PRETTY_NAME|NAME)=' /etc/os-release 2>/dev/null; cat /etc/openwrt_release 2>/dev/null | head -5)
printf '@@UPTIME@@\n'
uptime 2>/dev/null
printf '@@LOAD@@\n'
cat /proc/loadavg 2>/dev/null
printf '@@CPU@@\n'
grep -m1 -E 'model name|Hardware|cpu model' /proc/cpuinfo 2>/dev/null
nproc 2>/dev/null
printf '@@MEM@@\n'
cat /proc/meminfo 2>/dev/null
printf '@@DF@@\n'
df -hP 2>/dev/null || df -h 2>/dev/null
printf '@@NET@@\n'
ip -br addr 2>/dev/null || true
''');
    final sec = _sections(out);
    final host = (sec['HOST'] ?? '').trim().split('\n').first;
    final kernelLines = (sec['KERNEL'] ?? '').trim().split('\n');
    final kernel = kernelLines.where((e) => e.isNotEmpty).join(' · ');
    final osRaw = sec['OS'] ?? '';
    var osPretty = '';
    final pretty = RegExp(r'PRETTY_NAME="?([^"\n]+)"?').firstMatch(osRaw);
    if (pretty != null) {
      osPretty = pretty.group(1)!.trim();
    } else {
      final name = RegExp(r'^NAME="?([^"\n]+)"?', multiLine: true)
          .firstMatch(osRaw);
      osPretty = name?.group(1)?.trim() ??
          (osRaw.trim().isEmpty ? '' : osRaw.trim().split('\n').first);
    }
    final uptimeText = (sec['UPTIME'] ?? '').trim();
    double? l1, l5, l15;
    final loadParts = (sec['LOAD'] ?? '').trim().split(RegExp(r'\s+'));
    if (loadParts.length >= 3) {
      l1 = double.tryParse(loadParts[0]);
      l5 = double.tryParse(loadParts[1]);
      l15 = double.tryParse(loadParts[2]);
    }
    final cpuLines =
        (sec['CPU'] ?? '').trim().split('\n').where((e) => e.isNotEmpty);
    String cpuModel = '';
    int? cores;
    for (final line in cpuLines) {
      final m = RegExp(r':\s*(.+)').firstMatch(line);
      if (m != null) {
        cpuModel = m.group(1)!.trim();
      } else if (int.tryParse(line.trim()) != null) {
        cores = int.parse(line.trim());
      }
    }
    return BasicInfo(
      hostname: host,
      kernel: kernel,
      osPretty: osPretty,
      uptimeText: uptimeText,
      load1: l1,
      load5: l5,
      load15: l15,
      cpuModel: cpuModel,
      cpuCores: cores,
      mem: _parseMeminfo(sec['MEM'] ?? ''),
      disks: _parseDf(sec['DF'] ?? ''),
      ifaces: _parseIpBr(sec['NET'] ?? ''),
    );
  }

  MemInfo? _parseMeminfo(String raw) {
    int? total, free, avail, buffers, cached, swapT, swapF;
    for (final line in raw.split('\n')) {
      final p = line.split(RegExp(r'\s+'));
      if (p.length < 2) continue;
      final v = int.tryParse(p[1]);
      if (v == null) continue;
      switch (p[0]) {
        case 'MemTotal:':
          total = v;
        case 'MemFree:':
          free = v;
        case 'MemAvailable:':
          avail = v;
        case 'Buffers:':
          buffers = v;
        case 'Cached:':
          cached = v;
        case 'SwapTotal:':
          swapT = v;
        case 'SwapFree:':
          swapF = v;
      }
    }
    if (total == null || total <= 0) return null;
    final freeKb = free ?? 0;
    final used = total - freeKb - (buffers ?? 0) - (cached ?? 0);
    return MemInfo(
      totalKb: total,
      usedKb: used.clamp(0, total),
      freeKb: freeKb,
      availableKb: avail,
      swapTotalKb: swapT,
      swapUsedKb: (swapT != null && swapF != null) ? swapT - swapF : null,
    );
  }

  List<DiskInfo> _parseDf(String raw) {
    final list = <DiskInfo>[];
    for (final line in raw.split('\n')) {
      if (line.startsWith('Filesystem') || line.trim().isEmpty) continue;
      final p = line.split(RegExp(r'\s+'));
      if (p.length < 6) continue;
      final fs = p[0];
      if (fs.startsWith('tmpfs') ||
          fs.startsWith('devtmpfs') ||
          fs.startsWith('overlay') ||
          fs.contains('docker') ||
          fs.startsWith('udev')) {
        continue;
      }
      final mount = p.sublist(5).join(' ');
      if (mount.startsWith('/snap') || mount.startsWith('/run')) continue;
      final pctStr = p[4].replaceAll('%', '');
      list.add(DiskInfo(
        filesystem: fs,
        size: p[1],
        used: p[2],
        avail: p[3],
        usedPercent: int.tryParse(pctStr),
        mount: mount,
      ));
    }
    return list;
  }

  List<NetIface> _parseIpBr(String raw) {
    final list = <NetIface>[];
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final p = t.split(RegExp(r'\s+'));
      if (p.isEmpty) continue;
      final name = p[0];
      if (name == 'lo') continue;
      list.add(NetIface(
        name: name,
        state: p.length > 1 ? p[1] : '',
        addrs: p.length > 2 ? p.sublist(2).join(' ') : '',
      ));
    }
    return list;
  }

  Future<List<ProcessInfo>> _fetchProcesses() async {
    final out = await _run(
      r'''ps aux --sort=-%cpu 2>/dev/null | head -80 || ps w 2>/dev/null | head -80''',
    );
    final lines = out.split('\n');
    final list = <ProcessInfo>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line.isEmpty) continue;
      if (i == 0 && (line.contains('PID') || line.startsWith('USER'))) continue;
      final p = line.split(RegExp(r'\s+'));
      if (p.length < 11) {
        if (p.length >= 2) {
          list.add(ProcessInfo(pid: p.length > 1 ? p[1] : p[0], command: p.last));
        }
        continue;
      }
      list.add(ProcessInfo(
        user: p[0],
        pid: p[1],
        cpu: double.tryParse(p[2]),
        mem: double.tryParse(p[3]),
        command: p.sublist(10).join(' '),
      ));
    }
    return list;
  }

  Future<(List<ServiceInfo>, List<ServiceInfo>)> _fetchServices() async {
    final out = await _run(r'''
printf '@@RUN@@\n'
systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | head -100
printf '@@FAIL@@\n'
systemctl list-units --type=service --state=failed --no-legend --no-pager 2>/dev/null | head -40
printf '@@INIT@@\n'
ls /etc/init.d/ 2>/dev/null | head -60
''');
    final sec = _sections(out);
    final running = _parseSystemctl(sec['RUN'] ?? '');
    final failed = _parseSystemctl(sec['FAIL'] ?? '');
    if (running.isEmpty && failed.isEmpty) {
      final init = (sec['INIT'] ?? '')
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.startsWith('.'))
          .map((e) => ServiceInfo(
                name: e,
                active: 'init.d',
                description: 'SysV / OpenWrt',
              ))
          .toList();
      return (init, <ServiceInfo>[]);
    }
    return (running, failed);
  }

  List<ServiceInfo> _parseSystemctl(String raw) {
    final list = <ServiceInfo>[];
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final p = t.split(RegExp(r'\s+'));
      if (p.length < 4) continue;
      list.add(ServiceInfo(
        name: p[0].replaceAll('.service', ''),
        load: p[1],
        active: p[2],
        sub: p[3],
        description: p.length > 4 ? p.sublist(4).join(' ') : '',
      ));
    }
    return list;
  }

  Future<FirewallInfo> _fetchFirewall() async {
    final out = await _run(r'''
printf '@@UFW@@\n'
ufw status 2>/dev/null | head -40
printf '@@FWCMD@@\n'
firewall-cmd --state 2>/dev/null
firewall-cmd --list-all 2>/dev/null | head -40
printf '@@IPT@@\n'
iptables -L -n 2>/dev/null | head -60
printf '@@NFT@@\n'
nft list ruleset 2>/dev/null | head -40
''');
    final sec = _sections(out);
    final highlights = <String>[];
    final ufw = (sec['UFW'] ?? '').trim();
    if (ufw.isNotEmpty && !ufw.toLowerCase().contains('command not found')) {
      highlights.add('UFW\n$ufw');
    }
    final fw = (sec['FWCMD'] ?? '').trim();
    if (fw.isNotEmpty) highlights.add('firewalld\n$fw');
    final ipt = (sec['IPT'] ?? '').trim();
    if (ipt.isNotEmpty) {
      final chains = RegExp(r'^Chain\s+(\S+)', multiLine: true)
          .allMatches(ipt)
          .map((m) => m.group(1)!)
          .toList();
      highlights.add(
        'iptables · ${chains.isEmpty ? "规则" : chains.join(", ")}\n'
        '${ipt.split("\n").take(25).join("\n")}',
      );
    }
    final nft = (sec['NFT'] ?? '').trim();
    if (nft.isNotEmpty) {
      highlights.add('nftables\n${nft.split("\n").take(20).join("\n")}');
    }
    if (highlights.isEmpty) {
      return const FirewallInfo(summary: '未检测到常见防火墙，或当前用户无权限查看');
    }
    return FirewallInfo(
      summary: '已识别 ${highlights.length} 类防火墙配置',
      highlights: highlights,
    );
  }

  Future<PowerInfo> _fetchPower() async {
    final out = await _run(r'''
printf '@@UP@@\n'
uptime -p 2>/dev/null || uptime 2>/dev/null
printf '@@BOOT@@\n'
who -b 2>/dev/null || true
printf '@@BAT@@\n'
for d in /sys/class/power_supply/*; do
  [ -d "$d" ] || continue
  echo "NAME=$(basename "$d")"
  echo -n "TYPE="; cat "$d/type" 2>/dev/null; echo
  echo -n "STATUS="; cat "$d/status" 2>/dev/null; echo
  echo -n "CAP="; cat "$d/capacity" 2>/dev/null; echo
  echo "---"
done
printf '@@TEMP@@\n'
for t in /sys/class/thermal/thermal_zone*/temp; do
  [ -f "$t" ] || continue
  echo "$(basename "$(dirname "$t")"): $(cat "$t" 2>/dev/null)"
done
vcgencmd measure_temp 2>/dev/null || true
printf '@@LAST@@\n'
last -x 2>/dev/null | head -15 || true
''');
    final sec = _sections(out);
    final bats = <BatteryInfo>[];
    String? name, type, status;
    int? cap;
    for (final line in (sec['BAT'] ?? '').split('\n')) {
      if (line.startsWith('NAME=')) {
        name = line.substring(5).trim();
      } else if (line.startsWith('TYPE=')) {
        type = line.substring(5).trim();
      } else if (line.startsWith('STATUS=')) {
        status = line.substring(7).trim();
      } else if (line.startsWith('CAP=')) {
        cap = int.tryParse(line.substring(4).trim());
      } else if (line.trim() == '---' && name != null) {
        bats.add(BatteryInfo(
          name: name,
          type: type ?? '',
          status: status ?? '',
          capacity: cap,
        ));
        name = type = status = null;
        cap = null;
      }
    }
    final temps = (sec['TEMP'] ?? '')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) {
          final m = RegExp(r'^(.*?):\s*(\d+)$').firstMatch(e);
          if (m != null) {
            final milli = int.tryParse(m.group(2)!);
            if (milli != null && milli > 1000) {
              return '${m.group(1)}: ${(milli / 1000).toStringAsFixed(1)} °C';
            }
          }
          return e;
        })
        .toList();
    final events = (sec['LAST'] ?? '')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return PowerInfo(
      uptimeText: (sec['UP'] ?? '').trim(),
      bootTime: (sec['BOOT'] ?? '').trim(),
      batteries: bats,
      temps: temps,
      recentEvents: events,
    );
  }

  Future<List<UserInfo>> _fetchUsers() async {
    final out = await _run(r'''
printf '@@WHO@@\n'
who 2>/dev/null
printf '@@PASSWD@@\n'
cat /etc/passwd 2>/dev/null
''');
    final sec = _sections(out);
    final logged = <String>{};
    for (final line in (sec['WHO'] ?? '').split('\n')) {
      final p = line.trim().split(RegExp(r'\s+'));
      if (p.isNotEmpty && p.first.isNotEmpty) logged.add(p.first);
    }
    final list = <UserInfo>[];
    for (final line in (sec['PASSWD'] ?? '').split('\n')) {
      final p = line.split(':');
      if (p.length < 7) continue;
      list.add(UserInfo(
        name: p[0],
        uid: p[2],
        gid: p[3],
        home: p[5],
        shell: p[6],
        loggedIn: logged.contains(p[0]),
      ));
    }
    list.sort((a, b) {
      if (a.loggedIn != b.loggedIn) return a.loggedIn ? -1 : 1;
      return (int.tryParse(a.uid) ?? 0).compareTo(int.tryParse(b.uid) ?? 0);
    });
    return list;
  }

  Future<List<CronEntry>> _fetchCron() async {
    final out = await _run(r'''
printf '@@USER@@\n'
crontab -l 2>/dev/null
printf '@@ROOT@@\n'
cat /etc/crontabs/root 2>/dev/null
printf '@@ETC@@\n'
cat /etc/crontab 2>/dev/null
printf '@@D@@\n'
for f in /etc/cron.d/*; do
  [ -f "$f" ] || continue
  echo "## FILE:$f"
  cat "$f" 2>/dev/null
done
''');
    final sec = _sections(out);
    final list = <CronEntry>[];
    void parseBlock(String source, String body) {
      for (final line in body.split('\n')) {
        final t = line.trim();
        if (t.isEmpty ||
            t.startsWith('#') ||
            t.startsWith('SHELL=') ||
            t.startsWith('PATH=') ||
            t.startsWith('MAILTO=')) {
          continue;
        }
        final p = t.split(RegExp(r'\s+'));
        if (p.length < 6) {
          list.add(CronEntry(source: source, command: t));
          continue;
        }
        list.add(CronEntry(
          source: source,
          schedule: p.sublist(0, 5).join(' '),
          command: p.sublist(5).join(' '),
        ));
      }
    }

    parseBlock('用户 crontab', sec['USER'] ?? '');
    parseBlock('OpenWrt root', sec['ROOT'] ?? '');
    parseBlock('/etc/crontab', sec['ETC'] ?? '');
    String? file;
    final buf = StringBuffer();
    for (final line in (sec['D'] ?? '').split('\n')) {
      if (line.startsWith('## FILE:')) {
        if (file != null) parseBlock(file, buf.toString());
        file = line.substring(8).trim();
        buf.clear();
      } else {
        buf.writeln(line);
      }
    }
    if (file != null) parseBlock(file, buf.toString());
    return list;
  }

  Future<DockerInfo> _fetchDocker() async {
    final out = await _run(r'''
printf '@@VER@@\n'
docker --version 2>/dev/null || echo NO_DOCKER
printf '@@PS@@\n'
docker ps -a --format '{{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null
printf '@@IMG@@\n'
docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>/dev/null
''');
    final sec = _sections(out);
    final ver = (sec['VER'] ?? '').trim();
    if (ver.contains('NO_DOCKER') || ver.isEmpty) {
      return const DockerInfo(
        available: false,
        errorHint: '未安装 Docker，或不在 PATH / 无权限',
      );
    }
    final containers = <DockerContainer>[];
    for (final line in (sec['PS'] ?? '').split('\n')) {
      final p = line.split('\t');
      if (p.length < 4) continue;
      containers.add(DockerContainer(
        id: p[0],
        image: p[1],
        status: p[2],
        names: p[3],
        ports: p.length > 4 ? p[4] : '',
      ));
    }
    final images = <DockerImage>[];
    for (final line in (sec['IMG'] ?? '').split('\n')) {
      final p = line.split('\t');
      if (p.length < 4) continue;
      images.add(DockerImage(
        repository: p[0],
        tag: p[1],
        id: p[2],
        size: p[3],
      ));
    }
    return DockerInfo(
      available: true,
      versionLine: ver,
      containers: containers,
      images: images,
    );
  }

  Map<String, String> _sections(String raw) {
    final map = <String, String>{};
    final re = RegExp(r'@@(\w+)@@\n');
    final matches = re.allMatches(raw).toList();
    for (var i = 0; i < matches.length; i++) {
      final key = matches[i].group(1)!;
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      map[key] = raw.substring(start, end);
    }
    return map;
  }

  Future<void> close() async {
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    connected = false;
  }

  void dispose() {
    close();
    loaded.clear();
    loading.clear();
    errors.clear();
  }
}
