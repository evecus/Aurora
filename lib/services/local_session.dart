import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

import 'package:aurora/services/ssh_session.dart' show SshSessionState;

/// 本机 shell 会话（参照 server_box [LocalShellBackend]）。
///
/// 使用 [flutter_pty] 打开真正的伪终端，因此有提示符、可 resize、
/// 交互程序可用。Android 上启动 `/system/bin/sh`，
/// 并将 `HOME` 设为应用可写目录（与 server_box 一致）。
class LocalSession {
  LocalSession();

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

  /// 与 server_box 一致：Android 固定 `/system/bin/sh`。
  static String get shellPath {
    if (Platform.isWindows) {
      return Platform.environment['COMSPEC'] ?? 'cmd.exe';
    }
    if (Platform.isAndroid) return '/system/bin/sh';
    final preferred = Platform.environment['SHELL'];
    if (preferred != null && preferred.isNotEmpty) return preferred;
    return '/bin/sh';
  }

  /// Android 无系统 HOME，使用应用文档目录作为可写工作目录。
  static Future<String?> _resolveHome() async {
    if (Platform.isAndroid) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        return dir.path;
      } catch (_) {
        return null;
      }
    }
    final env = Platform.environment;
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    return (home != null && home.isNotEmpty) ? home : null;
  }

  Future<void> connect() async {
    if (_state == SshSessionState.connecting ||
        _state == SshSessionState.connected) {
      return;
    }

    _setState(SshSessionState.connecting);
    errorMessage = null;
    _exited = false;

    try {
      final home = await _resolveHome();
      final cols = terminal.viewWidth > 0 ? terminal.viewWidth : 80;
      final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 24;

      final env = <String, String>{
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        if (home != null) 'HOME': home,
      };

      final pty = Pty.start(
        shellPath,
        arguments: const [],
        environment: env,
        workingDirectory: home,
        rows: rows,
        columns: cols,
      );
      _pty = pty;

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);

      // xterm → PTY
      terminal.onOutput = (data) {
        final bytes = utf8.encode(data);
        _pty?.write(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
      };

      // 真正的 PTY 支持 resize
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (width > 0 && height > 0) {
          _pty?.resize(height, width);
        }
      };

      // PTY → xterm（伪终端侧已合并 stdout/stderr）
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
      debugPrint('Local shell failed: $e\n$st');
      errorMessage = e.toString();
      terminal.write('\r\n\x1b[31mLocal shell failed: $e\x1b[0m\r\n');
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
      // 与 server_box 一致：先 SIGHUP 进程组，超时再 SIGKILL
      try {
        if (!Platform.isWindows) {
          try {
            Process.killPid(-pty.pid, ProcessSignal.sighup);
          } catch (_) {}
        }
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
