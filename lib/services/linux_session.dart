import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
class LinuxSession {
  LinuxSession();

  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();

  Pty? _pty;
  StreamSubscription<Uint8List>? _outSub;

  SshSessionState _state = SshSessionState.idle;
  SshSessionState get state => _state;

  String? errorMessage;

  final ValueNotifier<SshSessionState> stateNotifier =
      ValueNotifier(SshSessionState.idle);

  var _exited = false;

  void _setState(SshSessionState s) {
    _state = s;
    stateNotifier.value = s;
  }

  /// 传给 proot 的参数（全部默认，不提供配置）。
  static List<String> _prootArgs(String rootfs) {
    // 必须绑定：容器内需要可用的 /dev、/proc、/sys。
    final binds = <String>['/dev:/dev', '/proc:/proc', '/sys:/sys'];
    // 共享存储按需绑定：部分设备没有 /sdcard，绑定不存在的目录会让 proot 直接退出。
    for (final path in const ['/sdcard', '/storage', '/mnt']) {
      if (Directory(path).existsSync()) binds.add('$path:$path');
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

  static Map<String, String> get _env => const {
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': '/root',
        'SHELL': '/bin/sh',
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'LANG': 'C.UTF-8',
        'TMPDIR': '/tmp',
        'PWD': '/root',
        'USER': 'root',
      };

  Future<void> connect() async {
    if (_state == SshSessionState.connecting ||
        _state == SshSessionState.connected) {
      return;
    }

    _setState(SshSessionState.connecting);
    errorMessage = null;
    _exited = false;

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

      final cols = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
      final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

      final pty = Pty.start(
        proot,
        arguments: _prootArgs(rootfs.path),
        environment: {..._env, 'PROOT_LOADER': loader},
        workingDirectory: rootfs.path,
        rows: rows,
        columns: cols,
      );
      _pty = pty;

      terminal.onOutput = (data) {
        final bytes = utf8.encode(data);
        _pty?.write(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
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
        pty.kill(ProcessSignal.sighup);
      } catch (_) {}
      Future.delayed(const Duration(seconds: 3), () {
        if (_exited) return;
        try {
          pty.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });
    }

    if (_state != SshSessionState.failed) {
      _setState(SshSessionState.disconnected);
    }
  }

  Future<void> reconnect() async {
    await close();
    await Future.delayed(const Duration(milliseconds: 100));
    await connect();
  }

  void dispose() {
    close();
    stateNotifier.dispose();
  }
}
