import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:aurora/models/remote_file_entry.dart';
import 'package:aurora/models/server.dart';

enum SftpState {
  idle,
  connecting,
  ready,
  failed,
  closed,
}

/// 传输后端：真正的 SFTP，或 SSH 命令模拟（兼容无 sftp-server 的路由器）。
enum FileTransferMode {
  sftp,
  command,
}

/// 独立的文件会话（不占用终端 shell）。
///
/// 连接时先尝试 SFTP；若子系统不可用（如小米路由器 Dropbear 无 sftp-server），
/// 自动切换到命令模式（ls / cat / base64 / mkdir / rm / mv），UI 仍显示为文件浏览器。
class SftpSession {
  SftpSession({required this.server});

  final Server server;

  SSHClient? _client;
  SftpClient? _sftp;

  SftpState state = SftpState.idle;
  FileTransferMode mode = FileTransferMode.sftp;
  String? errorMessage;
  String currentPath = '/';

  final ValueNotifier<SftpState> stateNotifier = ValueNotifier(SftpState.idle);
  final ValueNotifier<List<RemoteFileEntry>> entries = ValueNotifier(const []);
  final ValueNotifier<bool> loading = ValueNotifier(false);
  final ValueNotifier<FileTransferMode> modeNotifier =
      ValueNotifier(FileTransferMode.sftp);

  void _setState(SftpState s) {
    state = s;
    stateNotifier.value = s;
  }

  void _setMode(FileTransferMode m) {
    mode = m;
    modeNotifier.value = m;
  }

  Future<void> connect({String? initialPath}) async {
    if (state == SftpState.connecting || state == SftpState.ready) return;

    _setState(SftpState.connecting);
    errorMessage = null;
    loading.value = true;

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

      // 1) 先试 SFTP
      var usedSftp = false;
      try {
        _sftp = await _client!.sftp();
        String path = initialPath ?? '/';
        if (initialPath == null) {
          try {
            final home = await _sftp!.absolute('.');
            if (home.isNotEmpty) path = home;
          } catch (_) {}
        }
        _setMode(FileTransferMode.sftp);
        usedSftp = true;
        _setState(SftpState.ready);
        await list(path);
      } catch (e, st) {
        debugPrint('SFTP unavailable, fallback to command mode: $e\n$st');
        try {
          _sftp?.close();
        } catch (_) {}
        _sftp = null;

        // 2) 命令模式：确认能跑 ls
        final probe = await _runCommand('echo ok');
        if (!probe.trim().contains('ok')) {
          throw Exception('SSH 已连接，但无法执行命令（SFTP 与命令模式均失败）');
        }

        String path = initialPath ?? '/';
        if (initialPath == null) {
          try {
            final home = (await _runCommand('pwd')).trim();
            if (home.isNotEmpty && home.startsWith('/')) path = home;
          } catch (_) {}
        }

        _setMode(FileTransferMode.command);
        _setState(SftpState.ready);
        await list(path);
        debugPrint('Using command-mode file browser for ${server.host}');
      }

      if (!usedSftp && mode != FileTransferMode.command) {
        // 理论上不会走到这里
      }
    } catch (e, st) {
      debugPrint('File session connect failed: $e\n$st');
      errorMessage = e.toString();
      _setState(SftpState.failed);
      await close();
    } finally {
      loading.value = false;
    }
  }

  Future<void> list(String path) async {
    if (_client == null) return;

    loading.value = true;
    try {
      final normalized = _normalize(path);
      final List<RemoteFileEntry> items;
      if (mode == FileTransferMode.sftp) {
        items = await _listSftp(normalized);
      } else {
        items = await _listCommand(normalized);
      }

      items.sort((a, b) {
        if (a.isDotDot != b.isDotDot) return a.isDotDot ? -1 : 1;
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });

      currentPath = normalized;
      entries.value = items;
    } catch (e, st) {
      debugPrint('list failed ($mode): $e\n$st');
      errorMessage = e.toString();
      rethrow;
    } finally {
      loading.value = false;
    }
  }

  Future<List<RemoteFileEntry>> _listSftp(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final names = await sftp.listdir(path);
    return names
        .where((e) => e.filename != '.')
        .map(
          (e) => RemoteFileEntry(
            filename: e.filename,
            isDirectory: e.attr.isDirectory,
            size: e.attr.size,
            modifyTime: e.attr.modifyTime,
            longname: e.longname,
          ),
        )
        .toList();
  }

  /// 解析 `ls -la` 输出。兼容 busybox / coreutils。
  Future<List<RemoteFileEntry>> _listCommand(String path) async {
    final escaped = _shellQuote(path);
    // -A 不显示 . 与 ..，我们自己补 ..
    // 有的 busybox 没有 -A，用 -a 再过滤
    final raw = await _runCommand('ls -la $escaped 2>/dev/null || ls -l $escaped');
    final lines = raw.split('\n');
    final items = <RemoteFileEntry>[];

    if (path != '/') {
      items.add(const RemoteFileEntry(
        filename: '..',
        isDirectory: true,
      ));
    }

    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      // total 123
      if (trimmed.startsWith('total ')) continue;

      final entry = _parseLsLine(trimmed);
      if (entry == null) continue;
      if (entry.filename == '.' || entry.filename == '..') continue;
      items.add(entry);
    }
    return items;
  }

  /// 粗略解析 `ls -l` 一行。
  /// 例: drwxr-xr-x  2 root root  4096 Jan  1 12:00 dirname
  ///     -rw-r--r--  1 root root   123 Jan  1 12:00 file name with spaces
  static RemoteFileEntry? _parseLsLine(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 6) return null;

    final mode = parts[0];
    if (mode.length < 10) return null;
    final isDir = mode.startsWith('d') || mode.startsWith('l');

    // 找 size：通常在第 5 列（0-based index 4），对 ls -l 标准格式
    // permissions links owner group size month day time/year name...
    int? size;
    int nameIndex = 8;
    if (parts.length >= 9) {
      size = int.tryParse(parts[4]);
      nameIndex = 8;
    } else if (parts.length >= 6) {
      // 极简 busybox 可能列更少
      size = int.tryParse(parts[parts.length - 2]);
      nameIndex = parts.length - 1;
    }

    if (nameIndex >= parts.length) return null;
    var name = parts.sublist(nameIndex).join(' ');
    // 符号链接：name -> target
    if (mode.startsWith('l') && name.contains(' -> ')) {
      name = name.split(' -> ').first;
    }
    if (name.isEmpty) return null;

    return RemoteFileEntry(
      filename: name,
      isDirectory: isDir,
      size: isDir ? null : size,
      longname: line,
    );
  }

  Future<void> refresh() => list(currentPath);

  Future<void> cd(String name) async {
    if (name == '..') {
      await list(_parent(currentPath));
      return;
    }
    final next = currentPath == '/' ? '/$name' : '$currentPath/$name';
    await list(next);
  }

  Future<void> mkdir(String name) async {
    final path = currentPath == '/' ? '/$name' : '$currentPath/$name';
    if (mode == FileTransferMode.sftp) {
      final sftp = _sftp;
      if (sftp == null) throw StateError('SFTP not connected');
      await sftp.mkdir(path);
    } else {
      await _runCommand('mkdir -p ${_shellQuote(path)}');
    }
    await refresh();
  }

  Future<void> remove(RemoteFileEntry entry) async {
    final path = currentPath == '/'
        ? '/${entry.filename}'
        : '$currentPath/${entry.filename}';
    if (mode == FileTransferMode.sftp) {
      final sftp = _sftp;
      if (sftp == null) throw StateError('SFTP not connected');
      if (entry.isDirectory) {
        await sftp.rmdir(path);
      } else {
        await sftp.remove(path);
      }
    } else {
      // 路由器上 rmdir 常失败（非空），用 rm -rf 更实用
      await _runCommand('rm -rf ${_shellQuote(path)}');
    }
    await refresh();
  }

  Future<void> rename(String fromName, String toName) async {
    final from = currentPath == '/' ? '/$fromName' : '$currentPath/$fromName';
    final to = currentPath == '/' ? '/$toName' : '$currentPath/$toName';
    if (mode == FileTransferMode.sftp) {
      final sftp = _sftp;
      if (sftp == null) throw StateError('SFTP not connected');
      await sftp.rename(from, to);
    } else {
      await _runCommand('mv ${_shellQuote(from)} ${_shellQuote(to)}');
    }
    await refresh();
  }

  /// 读取整个文件到内存（适合小文件下载/编辑）。
  Future<Uint8List> readFile(String name) async {
    final path = currentPath == '/' ? '/$name' : '$currentPath/$name';
    if (mode == FileTransferMode.sftp) {
      final sftp = _sftp;
      if (sftp == null) throw StateError('SFTP not connected');
      final file = await sftp.open(path);
      try {
        final stat = await file.stat();
        final size = stat.size ?? 0;
        if (size <= 0) {
          final builder = BytesBuilder(copy: false);
          while (true) {
            final chunk = await file.readBytes();
            if (chunk.isEmpty) break;
            builder.add(chunk);
          }
          return builder.takeBytes();
        }
        return await file.readBytes(length: size);
      } finally {
        await file.close();
      }
    }

    // 命令模式：base64 避免二进制损坏；无 base64 时回退 cat（文本）
    final b64 = await _runCommand(
      'base64 ${_shellQuote(path)} 2>/dev/null || base64 < ${_shellQuote(path)} 2>/dev/null',
    );
    final cleaned = b64.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.isNotEmpty) {
      try {
        return Uint8List.fromList(base64Decode(cleaned));
      } catch (_) {
        // fall through
      }
    }
    final text = await _runCommand('cat ${_shellQuote(path)}');
    return Uint8List.fromList(utf8.encode(text));
  }

  Future<void> writeFile(String name, Uint8List data) async {
    final path = currentPath == '/' ? '/$name' : '$currentPath/$name';
    if (mode == FileTransferMode.sftp) {
      final sftp = _sftp;
      if (sftp == null) throw StateError('SFTP not connected');
      final file = await sftp.open(
        path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
      await refresh();
      return;
    }

    // 命令模式：通过 stdin 写入 base64 再解码，兼容二进制与特殊字符
    final encoded = base64Encode(data);
    final session = await _client!.execute(
      'base64 -d > ${_shellQuote(path)} 2>/dev/null || '
      'base64 -d > ${_shellQuote(path)}',
    );
    session.stdin.add(utf8.encode(encoded));
    await session.stdin.close();
    await session.done;
    // 部分系统 base64 参数是 -D（mac）或无 -d，再试管道写法
    final exit = session.exitCode;
    if (exit != null && exit != 0) {
      final session2 = await _client!.execute(
        'cat | base64 -d > ${_shellQuote(path)} || '
        'uudecode -o ${_shellQuote(path)} 2>/dev/null || '
        'cat > ${_shellQuote(path)}',
      );
      // 若无 base64，退化为文本写入（可能损坏二进制）
      final hasBase64 = (await _runCommand('command -v base64 || which base64'))
          .trim()
          .isNotEmpty;
      if (hasBase64) {
        session2.stdin.add(utf8.encode(encoded));
      } else {
        session2.stdin.add(data);
      }
      await session2.stdin.close();
      await session2.done;
    }
    await refresh();
  }

  Future<String> _runCommand(String command) async {
    final client = _client;
    if (client == null) throw StateError('SSH not connected');
    final result = await client.run(command);
    return utf8.decode(result, allowMalformed: true);
  }

  /// 单引号包裹，内部单引号转义为 '\'' 
  static String _shellQuote(String s) {
    if (s.isEmpty) return "''";
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  Future<void> close() async {
    try {
      _sftp?.close();
    } catch (_) {}
    _sftp = null;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    if (state != SftpState.failed) {
      _setState(SftpState.closed);
    }
  }

  void dispose() {
    close();
    stateNotifier.dispose();
    entries.dispose();
    loading.dispose();
    modeNotifier.dispose();
  }

  static String _normalize(String path) {
    if (path.isEmpty) return '/';
    var p = path.replaceAll(RegExp(r'/+'), '/');
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    if (!p.startsWith('/')) p = '/$p';
    return p.isEmpty ? '/' : p;
  }

  static String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final i = path.lastIndexOf('/');
    if (i <= 0) return '/';
    return path.substring(0, i);
  }
}
