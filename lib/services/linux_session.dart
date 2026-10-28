import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'package:aurora/services/linux_env.dart';
import 'package:aurora/services/ssh_session.dart' show SshSessionState;

/// 本机 Linux（proot + Alpine）shell 会话。
///
/// 与 [LocalSession] 同构：真 PTY，支持 resize、交互程序、提示符。
/// 区别是执行的不是 `/system/bin/sh`，而是
/// `libproot.so -r rootfs ... /bin/sh -l`。
///
/// 若设备已 Root 且 Magisk/su 授权本 App，则通过 `su -c` 以真实 root
/// 启动 proot，以便 ping / ip 等需要 CAP_NET_* 的命令可用；
/// 否则回退为普通 uid 启动（fake root `-0`）。
class LinuxSession {
  LinuxSession();

  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();

  Pty? _pty;
  StreamSubscription<Uint8List>? _outSub;

  SshSessionState _state = SshSessionState.idle;
  SshSessionState get state => _state;

  String? errorMessage;

  /// 本次会话是否以真实 root（su）启动。
  bool runningAsRoot = false;

  final ValueNotifier<SshSessionState> stateNotifier =
      ValueNotifier(SshSessionState.idle);

  var _exited = false;

  void _setState(SshSessionState s) {
    _state = s;
    stateNotifier.value = s;
  }

  /// 路径是否可访问（exists）；权限不足时当作不存在，不抛异常。
  static bool _accessible(String path) {
    try {
      return Directory(path).existsSync() || File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 传给 proot 的参数（全部默认，不提供配置）。
  static List<String> _prootArgs(String rootfs) {
    // 必须绑定：容器内需要可用的 /dev、/proc、/sys。
    final binds = <String>['/dev:/dev', '/proc:/proc', '/sys:/sys'];
    // 共享存储按需绑定：部分设备没有 /sdcard，绑定不存在的目录会让 proot 直接退出。
    // Android 上对部分路径 existsSync 会抛 Permission denied，必须吞掉。
    for (final path in const ['/sdcard', '/storage', '/mnt']) {
      if (_accessible(path)) binds.add('$path:$path');
    }
    // 部分 ROM 上 /dev/pts、/dev/shm 是独立挂载点，显式绑一次更稳。
    for (final path in const ['/dev/pts', '/dev/shm', '/dev/ashmem']) {
      if (_accessible(path)) binds.add('$path:$path');
    }

    return [
      '--kill-on-exit',
      '--link2symlink',
      '-0', // fake root：提示符为 root@，apk 可写 /root
      '-r', rootfs,
      '-w', '/root',
      for (final b in binds) ...['-b', b],
      '/bin/sh',
      '-l',
    ];
  }

  static Map<String, String> get _guestEnv => const {
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': '/root',
        'SHELL': '/bin/sh',
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'LANG': 'C.UTF-8',
        'PWD': '/root',
        'USER': 'root',
        // 注意：TMPDIR 不能写成 '/tmp' —— proot 建 glue rootfs 时读的是
        // 宿主视角的这个变量，Android 上没有可写的 /tmp。真正的值在
        // [connect] 里和 PROOT_TMP_DIR 一起指向应用私有目录。
      };

  /// 宿主侧 proot 运行环境（含 loader / tmp / seccomp）。
  static Map<String, String> _prootEnv(String loader, String tmpDir) => {
        ..._guestEnv,
        'PROOT_LOADER': loader,
        'PROOT_TMP_DIR': tmpDir,
        'TMPDIR': tmpDir,
        // Android 内核 seccomp 会拦截 guest 部分 syscall，表现为
        // "Bad system call"（ping / nano / 部分 apk 工具常见）。
        // Termux / proot-distro 同款：关闭 proot 的 seccomp 兼容层。
        'PROOT_NO_SECCOMP': '1',
      };

  /// 常见 su 路径（Android / Magisk / KernelSU）。
  static const _suCandidates = <String>[
    '/system/bin/su',
    '/system/xbin/su',
    '/sbin/su',
    '/su/bin/su',
    '/data/local/tmp/su',
  ];

  /// 定位可用的 su 可执行文件；没有则返回 null。
  static String? _findSuBinary() {
    for (final p in _suCandidates) {
      final f = File(p);
      if (f.existsSync()) return p;
    }
    // PATH 里碰运气（部分 ROM 给 App 配了 su）
    return null;
  }

  /// 探测 Magisk/su 是否已授权本 App（短超时，失败即当无 root）。
  static Future<String?> _detectSu() async {
    final su = _findSuBinary() ?? 'su';
    try {
      final r = await Process.run(
        su,
        const ['-c', 'id -u'],
        runInShell: false,
      ).timeout(const Duration(seconds: 3));
      final out = '${r.stdout}'.trim();
      if (r.exitCode == 0 && out == '0') return su;
    } on TimeoutException {
      debugPrint('linux: su detect timeout');
    } catch (e) {
      debugPrint('linux: su detect failed: $e');
    }
    return null;
  }

  /// shell 单引号转义：`'foo'bar'` → `'foo'\''bar'`
  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// 拼出 `su -c 'env...; exec proot ...'` 的完整命令字符串。
  static String _buildSuCommand({
    required String proot,
    required List<String> prootArgs,
    required Map<String, String> environment,
  }) {
    final exports = environment.entries
        .map((e) => 'export ${e.key}=${_shQuote(e.value)}')
        .join('; ');
    final exec = 'exec ${_shQuote(proot)} ${prootArgs.map(_shQuote).join(' ')}';
    return '$exports; $exec';
  }

  Future<void> connect() async {
    if (_state == SshSessionState.connecting ||
        _state == SshSessionState.connected) {
      return;
    }

    _setState(SshSessionState.connecting);
    errorMessage = null;
    _exited = false;
    runningAsRoot = false;

    try {
      final env = LinuxEnv.instance;

      if (!await env.isInstalled) {
        throw LinuxEnvException('Alpine 未部署，请到设置中开启 Linux 终端');
      }
      final proot = await env.prootPath();
      if (proot == null) {
        throw LinuxEnvException('找不到 proot（libproot.so）');
      }
      // proot 必须自带 loader 才能执行 rootfs 里的二进制：
      // targetSdk 29+ 下应用目录不可 exec，loader 在 nativeLibraryDir 才可执行。
      final loader = await env.loaderPath();
      if (loader == null) {
        throw LinuxEnvException('找不到 proot loader（libproot-loader.so）');
      }
      final rootfs = await env.rootfsDir();
      // 宿主机视角的可写临时目录：proot 在这里建 glue rootfs。
      final tmpDir = await env.ensureProotTmpDir();

      final cols = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
      final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

      final prootArgs = _prootArgs(rootfs.path);
      final prootEnv = _prootEnv(loader, tmpDir);

      // 优先尝试真实 root；失败则回退普通 uid。
      final su = await _detectSu();
      late final Pty pty;
      if (su != null) {
        final cmd = _buildSuCommand(
          proot: proot,
          prootArgs: prootArgs,
          environment: prootEnv,
        );
        debugPrint('linux: starting proot via $su');
        try {
          pty = Pty.start(
            su,
            arguments: ['-c', cmd],
            // su 自身环境尽量干净；guest/proot 变量已写进 -c 脚本。
            environment: {
              'PATH': '/system/bin:/system/xbin:/sbin:/bin',
              'TERM': 'xterm-256color',
            },
            workingDirectory: rootfs.path,
            rows: rows,
            columns: cols,
          );
          runningAsRoot = true;
        } catch (e) {
          debugPrint('linux: su start failed, fallback: $e');
          pty = Pty.start(
            proot,
            arguments: prootArgs,
            environment: prootEnv,
            workingDirectory: rootfs.path,
            rows: rows,
            columns: cols,
          );
          runningAsRoot = false;
        }
      } else {
        debugPrint('linux: no su, start proot as app uid');
        pty = Pty.start(
          proot,
          arguments: prootArgs,
          environment: prootEnv,
          workingDirectory: rootfs.path,
          rows: rows,
          columns: cols,
        );
        runningAsRoot = false;
      }
      _pty = pty;

      // xterm → PTY（utf8.encode 的结果本身就是 Uint8List）
      terminal.onOutput = (data) {
        _pty?.write(utf8.encode(data));
      };

      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (width > 0 && height > 0) {
          _pty?.resize(height, width);
        }
      };

      _outSub = pty.output.listen(
        (data) {
          terminal.write(utf8.decode(data, allowMalformed: true));
        },
        onDone: _onPtyDone,
        onError: (e) {
          terminal.write('\r\n\x1b[31mpty error: $e\x1b[0m\r\n');
        },
      );

      unawaited(pty.exitCode.then((_) => _onPtyDone()));

      // 在终端里给一行提示，方便确认是否走了 root。
      if (runningAsRoot) {
        terminal.write(
          '\x1b[32m[Linux] 已通过 su 以 root 启动 proot\x1b[0m\r\n',
        );
      }

      _setState(SshSessionState.connected);
    } catch (e, st) {
      debugPrint('linux session failed: $e\n$st');
      errorMessage = e.toString();
      terminal.write('\r\n\x1b[31mLinux 启动失败: $e\x1b[0m\r\n');
      _setState(SshSessionState.failed);
      await close();
    }
  }

  void _onPtyDone() {
    if (_exited) return;
    _exited = true;
    if (_state == SshSessionState.disconnected) return;
    _setState(SshSessionState.disconnected);
  }

  Future<void> close() async {
    await _outSub?.cancel();
    _outSub = null;

    final pty = _pty;
    _pty = null;
    if (pty != null && !_exited) {
      // 先 SIGHUP 进程组，超时再 SIGKILL（与本机终端一致）。
      if (!Platform.isWindows) {
        try {
          Process.killPid(-pty.pid, ProcessSignal.sighup);
        } catch (_) {}
      }
      try {
        await pty.exitCode.timeout(const Duration(milliseconds: 400));
      } catch (_) {
        try {
          pty.kill();
        } catch (_) {}
      }
    }
    _exited = true;
    if (_state != SshSessionState.failed) {
      _setState(SshSessionState.disconnected);
    }
  }

  void dispose() {
    unawaited(close());
    stateNotifier.dispose();
    terminal.onOutput = null;
    terminal.onResize = null;
  }
}
