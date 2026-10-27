import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 本机 Linux（proot）环境的部署状态。
enum LinuxEnvState {
  /// 尚未检查。
  unknown,

  /// rootfs 不存在，需要部署。
  missing,

  /// 正在下载 rootfs。
  downloading,

  /// 正在解压/配置。
  extracting,

  /// 可用。
  ready,

  /// 部署失败。
  failed,
}

/// 部署失败时的错误（直接展示给用户，toString 不带前缀）。
class LinuxEnvException implements Exception {
  LinuxEnvException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 本机 Linux 环境（proot + Alpine minirootfs）。
///
/// 全部使用默认值，不提供任何配置项（与需求一致）：
/// - 发行版：Alpine 3.22.5
/// - 镜像：官方 dl-cdn.alpinelinux.org
/// - DNS：1.1.1.1 / 8.8.8.8
/// - 位置：应用 files 目录 `linux/rootfs`
///
/// 部署由设置里的开关触发，rootfs 的清理也在设置里完成。
class LinuxEnv {
  LinuxEnv._();

  static final LinuxEnv instance = LinuxEnv._();

  /// 与 Android 侧 `MainActivity` 对应的通道，用于取 nativeLibraryDir。
  static const MethodChannel _channel = MethodChannel('aurora/proot');

  /// —— 默认配置（无自定义入口）——
  static const String version = '3.22.5';
  static const String arch = 'aarch64';
  static const String mirror = 'https://dl-cdn.alpinelinux.org';
  static const List<String> dns = ['1.1.1.1', '8.8.8.8'];

  static String get _major => 'v${version.split('.').take(2).join('.')}';

  String get _rootfsUrl =>
      '$mirror/alpine/$_major/releases/$arch/'
      'alpine-minirootfs-$version-$arch.tar.gz';

  final ValueNotifier<LinuxEnvState> stateNotifier =
      ValueNotifier(LinuxEnvState.unknown);

  /// 0.0 ~ 1.0，下载阶段占 85%，其余为解压/配置。
  final ValueNotifier<double> progressNotifier = ValueNotifier(0);

  /// 人类可读的进度文案。
  final ValueNotifier<String> messageNotifier = ValueNotifier('');

  String? error;

  LinuxEnvState get state => stateNotifier.value;
  double get progress => progressNotifier.value;
  String get message => messageNotifier.value;

  bool _installing = false;

  void _setState(LinuxEnvState s, {String msg = '', double? progress}) {
    stateNotifier.value = s;
    messageNotifier.value = msg;
    if (progress != null) progressNotifier.value = progress;
  }

  /// nativeLibraryDir：proot 以 `libproot.so` 打包在这里，
  /// 因为 targetSdk 36 下应用私有目录不允许 exec 可执行文件。
  Future<String> nativeLibraryDir() async {
    try {
      final dir = await _channel.invokeMethod<String>('getNativeLibraryDir');
      if (dir != null && dir.isNotEmpty) return dir;
    } catch (e) {
      debugPrint('getNativeLibraryDir failed: $e');
    }
    return '';
  }

  /// proot 可执行文件路径，不存在返回 null。
  ///
  /// 两个文件都必须存在，缺一不可：
  /// - `libproot.so`：proot 本体；
  /// - `libproot-loader.so`：proot 的 loader。
  ///
  /// targetSdk 29+ 不允许 exec 应用私有目录里的文件，而 rootfs 全在那里。
  /// proot 不是靠权限绕过的：它用自带的 loader 映射 guest ELF 并交给 guest
  /// 自己的解释器，**不对 guest 二进制调用 execve**。前提是这个 loader 自己
  /// 得可执行 —— 不指定 `PROOT_LOADER` 时，proot 会把内嵌的 loader 解包到
  /// 临时目录（正是应用私有目录），exec 失败后退回普通 execve，报
  /// `execve(...): Permission denied`。此处与 fl_tty / server_box 的处理一致。
  Future<String?> prootPath() async {
    if (!Platform.isAndroid) return null;
    final dir = await nativeLibraryDir();
    if (dir.isEmpty) return null;
    final path = '$dir/libproot.so';
    return File(path).existsSync() ? path : null;
  }

  /// proot loader 路径（nativeLibraryDir 下才允许执行）。
  Future<String?> loaderPath() async {
    if (!Platform.isAndroid) return null;
    final dir = await nativeLibraryDir();
    if (dir.isEmpty) return null;
    final path = '$dir/libproot-loader.so';
    return File(path).existsSync() ? path : null;
  }

  /// 存放 rootfs 的父目录（`<files>/linux`）。
  Future<Directory> linuxDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/linux');
  }

  Future<Directory> rootfsDir() async {
    final base = await linuxDir();
    return Directory('${base.path}/rootfs');
  }

  Future<bool> get isInstalled async {
    final dir = await rootfsDir();
    return File('${dir.path}/bin/sh').existsSync();
  }

  /// rootfs 占用字节数（递归统计，可能较慢）。
  Future<int> sizeBytes() async {
    final dir = await rootfsDir();
    if (!dir.existsSync()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      try {
        if (entity is File) total += await entity.length();
      } catch (_) {}
    }
    return total;
  }

  /// 刷新状态（不触发部署）。
  Future<void> refresh() async {
    if (_installing) return;
    final installed = await isInstalled;
    _setState(
      installed ? LinuxEnvState.ready : LinuxEnvState.missing,
      progress: installed ? 1 : 0,
    );
  }

  /// 部署 Alpine rootfs。已部署则直接返回，重复调用安全。
  Future<void> install() async {
    if (_installing) return;
    if (await isInstalled) {
      _setState(LinuxEnvState.ready, msg: '已部署', progress: 1);
      return;
    }

    _installing = true;
    error = null;
    try {
      if (!Platform.isAndroid) {
        throw LinuxEnvException('本机 Linux 仅在 Android 上可用');
      }
      final proot = await prootPath();
      if (proot == null) {
        throw LinuxEnvException('缺少 proot（libproot.so 未随包安装）');
      }
      if (await loaderPath() == null) {
        throw LinuxEnvException('缺少 proot loader（libproot-loader.so 未随包安装）');
      }

      final base = await linuxDir();
      if (!base.existsSync()) base.createSync(recursive: true);
      final rootfs = Directory('${base.path}/rootfs');
      // 上一轮解压不完整时直接重建，避免残留文件干扰。
      if (rootfs.existsSync()) rootfs.deleteSync(recursive: true);
      rootfs.createSync(recursive: true);
      final archive = File('${base.path}/rootfs.tar.gz');

      await _download(archive);
      await _extract(archive, rootfs);
      await _configure(rootfs);

      if (archive.existsSync()) archive.deleteSync();
      _setState(LinuxEnvState.ready, msg: '部署完成', progress: 1);
    } catch (e, st) {
      debugPrint('linux deploy failed: $e\n$st');
      error = e.toString();
      _setState(LinuxEnvState.failed, msg: e.toString());
    } finally {
      _installing = false;
    }
  }

  /// 清理 rootfs（下一个开关开启时会重新部署）。
  Future<void> uninstall() async {
    if (_installing) return;
    final base = await linuxDir();
    if (base.existsSync()) base.deleteSync(recursive: true);
    error = null;
    _setState(LinuxEnvState.missing, msg: '', progress: 0);
  }

  /// 下载 minirootfs，进度写入 [progressNotifier]。
  Future<void> _download(File target) async {
    _setState(LinuxEnvState.downloading, msg: '下载 Alpine $version…', progress: 0);

    final client = HttpClient();
    HttpClientRequest request;
    try {
      request = await client.getUrl(Uri.parse(_rootfsUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'aurora');
    } catch (e) {
      client.close(force: true);
      throw LinuxEnvException('无法连接镜像：$e');
    }

    HttpClientResponse response;
    try {
      response = await request.close();
    } catch (e) {
      client.close(force: true);
      throw LinuxEnvException('下载失败：$e');
    }

    if (response.statusCode != 200) {
      client.close(force: true);
      throw LinuxEnvException('镜像返回 ${response.statusCode}');
    }

    final total = response.contentLength;
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final ratio = total > 0 ? received / total : 0.0;
        progressNotifier.value = 0.85 * ratio.clamp(0.0, 1.0);
        messageNotifier.value =
            '下载 Alpine $version：${_humanBytes(received)}${total > 0 ? ' / ${_humanBytes(total)}' : ''}';
      }
      await sink.flush();
    } catch (e) {
      throw LinuxEnvException('下载中断：$e');
    } finally {
      await sink.close();
      client.close(force: true);
    }

    if (received == 0) throw LinuxEnvException('下载内容为空');
  }

  /// 解压 rootfs：优先用系统 gzip+tar，失败回退到 Dart 解压。
  Future<void> _extract(File archive, Directory rootfs) async {
    _setState(LinuxEnvState.extracting, msg: '解压 rootfs…', progress: 0.88);

    final ok = await _extractWithSystemTar(archive, rootfs) ||
        await _extractWithDart(archive, rootfs);

    if (!ok) throw LinuxEnvException('解压失败');

    if (!File('${rootfs.path}/bin/sh').existsSync()) {
      throw LinuxEnvException('rootfs 不完整（缺少 /bin/sh）');
    }
    progressNotifier.value = 0.95;
  }

  /// Android 的 toybox 自带 gzip / tar，比 Dart 快得多。
  Future<bool> _extractWithSystemTar(File archive, Directory rootfs) async {
    try {
      final result = await Process.run('/system/bin/sh', [
        '-c',
        '/system/bin/gzip -dc "${archive.path}" | /system/bin/tar -xf - -C "${rootfs.path}"',
      ]);
      if (result.exitCode == 0) {
        return File('${rootfs.path}/bin/sh').existsSync();
      }
      debugPrint('system tar failed: ${result.exitCode} ${result.stderr}');
    } catch (e) {
      debugPrint('system tar error: $e');
    }
    return false;
  }

  /// 纯 Dart 兜底：gzip 用 dart:io，tar 自己解（仅需普通文件/目录/符号链接）。
  Future<bool> _extractWithDart(File archive, Directory rootfs) async {
    late final Uint8List tarBytes;
    try {
      final raw = await archive.readAsBytes();
      tarBytes = gzip.decode(raw) as Uint8List;
    } catch (e) {
      debugPrint('gzip decode failed: $e');
      return false;
    }

    final extractor = _TarReader(tarBytes);
    var count = 0;
    await for (final entry in extractor.entries) {
      final path = '${rootfs.path}/${entry.name}';
      switch (entry.type) {
        case _TarEntryType.directory:
          Directory(path).createSync(recursive: true);
        case _TarEntryType.symlink:
          final link = Link(path);
          if (link.existsSync()) link.deleteSync();
          try {
            link.createSync(entry.linkName, recursive: true);
          } catch (_) {}
        case _TarEntryType.file:
          final file = File(path);
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(entry.content, flush: false);
        case _TarEntryType.other:
          // 硬链接 / 设备节点 / pax 头等：minirootfs 用不到，直接跳过。
          break;
      }
      count++;
      if (count % 200 == 0) {
        messageNotifier.value = '解压 $count 项…';
      }
    }

    // Dart 写文件无法设置可执行位，把常见可执行文件目录整体 chmod。
    for (final bin in ['bin', 'sbin', 'usr/bin', 'usr/sbin']) {
      final dir = Directory('${rootfs.path}/$bin');
      if (!dir.existsSync()) continue;
      try {
        await Process.run('/system/bin/chmod', ['-R', '755', dir.path]);
      } catch (_) {}
    }
    return true;
  }

  /// 写入 DNS / 软件源 / hosts，让 apk 与网络开箱可用。
  Future<void> _configure(Directory rootfs) async {
    _setState(LinuxEnvState.extracting, msg: '写入配置…', progress: 0.96);

    final etc = Directory('${rootfs.path}/etc');
    if (!etc.existsSync()) etc.createSync(recursive: true);

    File('${etc.path}/resolv.conf')
        .writeAsStringSync('${dns.map((d) => 'nameserver $d').join('\n')}\n');

    File('${etc.path}/apk/repositories').writeAsStringSync(
      '$mirror/alpine/$_major/main\n'
      '$mirror/alpine/$_major/community\n',
    );

    // rootfs 里没有 hosts，补一个最小的，避免解析 localhost 失败。
    File('${etc.path}/hosts').writeAsStringSync(
      '127.0.0.1\tlocalhost\n'
      '::1\tlocalhost ip6-localhost ip6-loopback\n',
    );

    // proot 下 /tmp 必须可写。
    final tmp = Directory('${rootfs.path}/tmp');
    if (!tmp.existsSync()) tmp.createSync(recursive: true);

    // 登录目录。
    final root = Directory('${rootfs.path}/root');
    if (!root.existsSync()) root.createSync(recursive: true);
  }
}

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// TAR 条目类型（只关心这几类，其余忽略）。
enum _TarEntryType { file, directory, symlink, other }

class _TarEntry {
  _TarEntry({
    required this.name,
    required this.type,
    required this.content,
    required this.linkName,
  });

  final String name;
  final _TarEntryType type;
  final Uint8List content;
  final String linkName;
}

/// 最小 TAR 解析器（ustar，512 字节头，8 进制字段）。
class _TarReader {
  _TarReader(this._bytes);

  final Uint8List _bytes;

  static const int _blockSize = 512;

  Stream<_TarEntry> get entries async* {
    var offset = 0;
    while (offset + _blockSize <= _bytes.length) {
      final header = _bytes.sublist(offset, offset + _blockSize);
      // 全零表示归档结束。
      if (header.every((b) => b == 0)) break;

      var name = _string(header, 0, 100);
      final prefix = _string(header, 345, 155);
      if (prefix.isNotEmpty) name = '$prefix/$name';

      final sizeField = _string(header, 124, 12).trim();
      final size = sizeField.isEmpty ? 0 : int.tryParse(sizeField, radix: 8) ?? 0;
      final typeFlag = header[156];
      final linkName = _string(header, 157, 100);

      offset += _blockSize;
      final end = (offset + size).clamp(0, _bytes.length);
      final content = size > 0
          ? Uint8List.sublistView(_bytes, offset, end)
          : Uint8List(0);
      // 数据按 512 字节对齐。
      offset += (size + _blockSize - 1) ~/ _blockSize * _blockSize;

      // 跳过路径中的 ./ 前缀与绝对路径，避免写到 rootfs 之外。
      name = name.replaceAll(RegExp(r'^\./'), '');
      while (name.startsWith('/')) {
        name = name.substring(1);
      }
      if (name.isEmpty || name.contains('..')) continue;

      final type = switch (typeFlag) {
        0x35 => _TarEntryType.directory, // '5'
        0x32 => _TarEntryType.symlink, // '2'
        0x30 || 0x00 => _TarEntryType.file, // '0' / 旧格式
        _ => _TarEntryType.other,
      };

      yield _TarEntry(
        name: name,
        type: type,
        content: content,
        linkName: linkName,
      );
    }
  }

  static String _string(Uint8List bytes, int start, int length) {
    final end = (start + length).clamp(0, bytes.length);
    for (var i = start; i < end; i++) {
      if (bytes[i] == 0) {
        return String.fromCharCodes(bytes, start, i);
      }
    }
    return String.fromCharCodes(bytes, start, end);
  }
}

/// 供 UI 展示的部署状态文案。
extension LinuxEnvStateX on LinuxEnvState {
  String get label => switch (this) {
        LinuxEnvState.unknown => '检查中',
        LinuxEnvState.missing => '未部署',
        LinuxEnvState.downloading => '下载中',
        LinuxEnvState.extracting => '部署中',
        LinuxEnvState.ready => '已部署',
        LinuxEnvState.failed => '部署失败',
      };
}
