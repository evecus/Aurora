/// 基础信息（结构化，用于卡片展示）
class BasicInfo {
  final String hostname;
  final String kernel;
  final String osPretty;
  final String uptimeText;
  final double? load1;
  final double? load5;
  final double? load15;
  final String cpuModel;
  final int? cpuCores;
  final MemInfo? mem;
  final List<DiskInfo> disks;
  final List<NetIface> ifaces;

  const BasicInfo({
    this.hostname = '',
    this.kernel = '',
    this.osPretty = '',
    this.uptimeText = '',
    this.load1,
    this.load5,
    this.load15,
    this.cpuModel = '',
    this.cpuCores,
    this.mem,
    this.disks = const [],
    this.ifaces = const [],
  });
}

class MemInfo {
  final int totalKb;
  final int usedKb;
  final int freeKb;
  final int? availableKb;
  final int? swapTotalKb;
  final int? swapUsedKb;

  const MemInfo({
    required this.totalKb,
    required this.usedKb,
    required this.freeKb,
    this.availableKb,
    this.swapTotalKb,
    this.swapUsedKb,
  });

  double get usedRatio {
    if (totalKb <= 0) return 0;
    final u = availableKb != null ? (totalKb - availableKb!) : usedKb;
    return (u / totalKb).clamp(0.0, 1.0);
  }

  String get usedLabel => _fmtKb(availableKb != null ? totalKb - availableKb! : usedKb);
  String get totalLabel => _fmtKb(totalKb);
}

class DiskInfo {
  final String filesystem;
  final String size;
  final String used;
  final String avail;
  final int? usedPercent;
  final String mount;

  const DiskInfo({
    required this.filesystem,
    required this.size,
    required this.used,
    required this.avail,
    this.usedPercent,
    required this.mount,
  });
}

class NetIface {
  final String name;
  final String state;
  final String addrs;

  const NetIface({
    required this.name,
    this.state = '',
    this.addrs = '',
  });
}

class ProcessInfo {
  final String user;
  final String pid;
  final double? cpu;
  final double? mem;
  final String command;

  const ProcessInfo({
    this.user = '',
    this.pid = '',
    this.cpu,
    this.mem,
    this.command = '',
  });
}

class ServiceInfo {
  final String name;
  final String load;
  final String active;
  final String sub;
  final String description;

  const ServiceInfo({
    required this.name,
    this.load = '',
    this.active = '',
    this.sub = '',
    this.description = '',
  });

  bool get isRunning =>
      active.toLowerCase() == 'active' ||
      sub.toLowerCase().contains('running');
  bool get isFailed =>
      active.toLowerCase() == 'failed' || load.toLowerCase() == 'failed';
}

class FirewallInfo {
  final String summary;
  final List<String> highlights;

  const FirewallInfo({this.summary = '', this.highlights = const []});
}

class PowerInfo {
  final String uptimeText;
  final String bootTime;
  final List<BatteryInfo> batteries;
  final List<String> temps;
  final List<String> recentEvents;

  const PowerInfo({
    this.uptimeText = '',
    this.bootTime = '',
    this.batteries = const [],
    this.temps = const [],
    this.recentEvents = const [],
  });
}

class BatteryInfo {
  final String name;
  final String type;
  final String status;
  final int? capacity;

  const BatteryInfo({
    required this.name,
    this.type = '',
    this.status = '',
    this.capacity,
  });
}

class UserInfo {
  final String name;
  final String uid;
  final String gid;
  final String home;
  final String shell;
  final bool loggedIn;

  const UserInfo({
    required this.name,
    this.uid = '',
    this.gid = '',
    this.home = '',
    this.shell = '',
    this.loggedIn = false,
  });
}

class CronEntry {
  final String source;
  final String schedule;
  final String command;

  const CronEntry({
    required this.source,
    this.schedule = '',
    this.command = '',
  });
}

class DockerContainer {
  final String id;
  final String image;
  final String status;
  final String names;
  final String ports;

  const DockerContainer({
    this.id = '',
    this.image = '',
    this.status = '',
    this.names = '',
    this.ports = '',
  });

  bool get isUp => status.toLowerCase().startsWith('up');
}

class DockerImage {
  final String repository;
  final String tag;
  final String id;
  final String size;

  const DockerImage({
    this.repository = '',
    this.tag = '',
    this.id = '',
    this.size = '',
  });
}

class DockerInfo {
  final bool available;
  final String versionLine;
  final List<DockerContainer> containers;
  final List<DockerImage> images;
  final String? errorHint;

  const DockerInfo({
    this.available = false,
    this.versionLine = '',
    this.containers = const [],
    this.images = const [],
    this.errorHint,
  });
}

String _fmtKb(int kb) {
  if (kb < 1024) return '$kb KB';
  if (kb < 1024 * 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
  return '${(kb / (1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
