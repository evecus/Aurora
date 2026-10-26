import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:aurora/models/server.dart';
import 'package:xterm/xterm.dart';

enum SshSessionState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
}

/// 一个独立的 SSH 终端会话：连接、PTY、与 xterm Terminal 双向绑定。
class SshSession {
  SshSession({required this.server});

  final Server server;

  final terminal = Terminal(
    maxLines: 10000,
  );

  final controller = TerminalController();

  SSHClient? _client;
  SSHSession? _shell;

  SshSessionState _state = SshSessionState.idle;
  SshSessionState get state => _state;

  String? errorMessage;

  final ValueNotifier<SshSessionState> stateNotifier =
      ValueNotifier(SshSessionState.idle);

  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  void _setState(SshSessionState s) {
    _state = s;
    stateNotifier.value = s;
  }

  /// 建立连接并打开交互式 shell。
  Future<void> connect() async {
    if (_state == SshSessionState.connecting ||
        _state == SshSessionState.connected) {
      return;
    }

    _setState(SshSessionState.connecting);
    errorMessage = null;
    terminal.write('\r\n\x1b[36m连接中 ${server.displayAddr}...\x1b[0m\r\n');

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

      terminal.write('\x1b[32m已连接\x1b[0m\r\n');

      _shell = await _client!.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
          height: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        ),
      );

      terminal.buffer.clear();
      terminal.buffer.setCursor(0, 0);

      terminal.onOutput = (data) {
        _shell?.write(utf8.encode(data));
      };

      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        _shell?.resizeTerminal(width, height);
      };

      _stdoutSub = _shell!.stdout.listen(
        (data) {
          terminal.write(utf8.decode(data, allowMalformed: true));
        },
        onDone: _onShellDone,
        onError: (e) {
          terminal.write('\r\n\x1b[31mstdout error: $e\x1b[0m\r\n');
        },
      );

      _stderrSub = _shell!.stderr.listen(
        (data) {
          terminal.write(utf8.decode(data, allowMalformed: true));
        },
      );

      _shell!.done.then((_) => _onShellDone());

      _setState(SshSessionState.connected);
    } catch (e, st) {
      debugPrint('SSH connect failed: $e\n$st');
      errorMessage = e.toString();
      terminal.write('\r\n\x1b[31m连接失败: $e\x1b[0m\r\n');
      _setState(SshSessionState.failed);
      await close();
    }
  }

  void _onShellDone() {
    if (_state == SshSessionState.disconnected ||
        _state == SshSessionState.failed) {
      return;
    }
    terminal.write('\r\n\x1b[33m已断开\x1b[0m\r\n');
    _setState(SshSessionState.disconnected);
  }

  Future<void> close() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;

    try {
      _client?.close();
    } catch (_) {}
    _client = null;

    if (_state == SshSessionState.connected) {
      terminal.write('\r\n\x1b[33m已断开\x1b[0m\r\n');
      _setState(SshSessionState.disconnected);
    } else if (_state != SshSessionState.failed &&
        _state != SshSessionState.disconnected) {
      _setState(SshSessionState.disconnected);
    }
  }

  Future<void> reconnect() async {
    await close();
    await connect();
  }

  void dispose() {
    close();
    stateNotifier.dispose();
  }
}
