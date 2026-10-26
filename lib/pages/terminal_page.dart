import 'dart:ui' show View;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/pages/sftp_page.dart';
import 'package:aurora/services/settings_store.dart';
import 'package:aurora/services/local_session.dart';
import 'package:aurora/services/ssh_session.dart';
import 'package:aurora/services/virt_key_input_handler.dart';
import 'package:aurora/widgets/virt_keys.dart';
import 'package:xterm/xterm.dart';

/// 完整 SSH 终端页：连接、渲染、虚拟按键、重连。
///
/// 与 server_box 对齐的交互：
/// - 长按终端：有选区则复制，无选区则粘贴；
/// - 虚拟按键条随手机输入法键盘一同显示/消失（输入法弹出时位于其上方）；
/// - Ctrl / Alt / Shift 点亮后与输入法键盘的字母等按键组合。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.server});

  final Server server;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with WidgetsBindingObserver {
  /// SSH 或本机会话（接口一致：terminal / controller / state / ...）。
  late final dynamic _session;
  final _terminalKey = GlobalKey<TerminalViewState>();
  final _focusNode = FocusNode();

  /// 修饰键状态机，同时挂载到 [Terminal.inputHandler]。
  late final VirtKeyInputHandler _inputHandler = VirtKeyInputHandler();

  /// 手机输入法键盘当前是否弹出。虚拟按键条随之显示/消失。
  ///
  /// 显示取 insets 上升沿，隐藏取焦点边沿（即时，不等 insets 动画
  /// 逐帧归零，保证虚拟条与键盘同步消失）。
  bool _imeVisible = false;

  /// 有选区时显示浮动工具条（复制 / 全选 / 粘贴）。
  bool _showCopyBar = false;

  final _settings = SettingsStore.instance;

  bool get _isLocal => widget.server.isLocal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChange);
    if (_isLocal) {
      _session = LocalSession();
    } else {
      _session = SshSession(server: widget.server);
    }
    // 修饰键经 inputHandler 生效：输入法键盘/物理键盘的按键都会带上。
    _session.terminal.inputHandler = _inputHandler;
    _session.stateNotifier.addListener(_onState);
    _session.controller.addListener(_onSelectionChanged);
    _settings.addListener(_onSettings);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.connect();
      _focusWithoutKeyboard();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.removeListener(_onFocusChange);
    _session.stateNotifier.removeListener(_onState);
    _session.controller.removeListener(_onSelectionChanged);
    _settings.removeListener(_onSettings);
    _session.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // 输入法弹出/收起会改变底部 viewInsets。
    final visible = View.of(context).viewInsets.bottom > 0;
    if (visible != _imeVisible && mounted) {
      setState(() => _imeVisible = visible);
    }
  }

  /// 焦点失去即键盘收起，立即同步隐藏虚拟按键条。
  void _onFocusChange() {
    if (!_focusNode.hasFocus && _imeVisible && mounted) {
      setState(() => _imeVisible = false);
    }
  }

  /// 选区出现/消失时显示/隐藏浮动工具条。
  void _onSelectionChanged() {
    final has = _session.controller.selection != null;
    if (has != _showCopyBar && mounted) {
      setState(() => _showCopyBar = has);
    }
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  /// 聚焦终端但不唤起输入法键盘（server_box 的 `keyboard: false` 行为）。
  void _focusWithoutKeyboard() {
    _focusNode.requestFocus();
    // 聚焦会顺势打开输入连接，延迟一帧后收起键盘。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    });
  }

  /// 切换手机输入法键盘（server_box 的 IME 键）。
  void _toggleIme() {
    if (_imeVisible) {
      _focusNode.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    } else {
      _focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    }
  }

  Future<void> _reconnect() async {
    await _session.reconnect();
    _focusWithoutKeyboard();
  }

  void _openSftp() {
    if (_isLocal) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpPage(server: widget.server),
      ),
    );
  }

  /// 长按终端：有选区复制，无选区粘贴（server_box 同款逻辑）。
  ///
  /// 选区出现时另有浮动工具条提供“复制 / 全选 / 粘贴”按钮。
  Future<void> _onClipboardAction() async {
    final selection = _session.controller.selection;
    if (selection != null) {
      await _copySelection();
      return;
    }
    await _pasteFromClipboard();
  }

  /// 复制当前选区到剪贴板（工具条“复制”按钮与长按共用）。
  Future<void> _copySelection() async {
    final selection = _session.controller.selection;
    if (selection == null) return;
    final text = _selectedText(selection);
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    }
    _session.controller.clearSelection();
  }

  /// 从剪贴板粘贴（长按无选区时与工具条“粘贴”按钮共用）。
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _session.terminal.paste(text);
    _session.controller.clearSelection();
  }

  /// 全选终端内容（pub 版 xterm 无 selectAll，自建选区）。
  void _selectAll() {
    final buffer = _session.terminal.buffer;
    if (buffer.height == 0) return;
    final lastLine = buffer.lines[buffer.height - 1];
    _session.controller.setSelection(
      buffer.createAnchorFromOffset(const CellOffset(0, 0)),
      buffer.createAnchorFromOffset(
        CellOffset(lastLine.length, buffer.height - 1),
      ),
    );
  }

  /// 从 buffer 中提取选区文本（server_box `renderTerminal.selectedText` 等价逻辑）。
  String _selectedText(BufferRange range) {
    final r = range.normalized;
    final lines = _session.terminal.buffer.lines;
    final sb = StringBuffer();
    for (var y = r.begin.y; y <= r.end.y; y++) {
      if (y < 0 || y >= lines.length) break;
      final from = y == r.begin.y ? r.begin.x : 0;
      final to = y == r.end.y ? r.end.x : null;
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(lines[y].getText(from, to));
    }
    return sb.toString();
  }

  Future<bool> _onWillPop() async {
    // 本机终端始终直接退出；SSH 仅在「终端退出确认」开启且已连接时弹窗。
    if (_isLocal) return true;
    if (_session.state != SshSessionState.connected) return true;
    if (!_settings.confirmExitTerminal) return true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开连接？'),
        content: const Text('当前会话仍在连接中，确定退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开并退出'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fontSize = _settings.fontSize;

    final termTheme = isDark ? _darkTheme : _lightTheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop()) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Stack(
        children: [
          Scaffold(
        backgroundColor: termTheme.background,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.server.name,
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                _isLocal
                    ? '本地 shell'
                    : '${widget.server.username}@${widget.server.displayAddr}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
          actions: [
            if (!_isLocal) ...[
              IconButton(
                tooltip: 'SFTP 文件',
                icon: const Icon(Icons.folder_outlined),
                onPressed: _openSftp,
              ),
              IconButton(
                tooltip: '重连',
                icon: const Icon(Icons.refresh),
                onPressed: _session.state == SshSessionState.connecting
                    ? null
                    : _reconnect,
              ),
              IconButton(
                tooltip: '断开',
                icon: const Icon(Icons.link_off),
                onPressed: _session.state == SshSessionState.connected
                    ? () async {
                        await _session.close();
                      }
                    : null,
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            if (_session.state == SshSessionState.connecting)
              const LinearProgressIndicator(minHeight: 2),
            if (_session.state == SshSessionState.failed)
              MaterialBanner(
                content: Text(
                  _session.errorMessage ?? '连接失败',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: const Icon(Icons.error_outline),
                actions: [
                  TextButton(
                    onPressed: _reconnect,
                    child: const Text('重试'),
                  ),
                ],
              ),
            Expanded(
              child: Stack(
                children: [
                  TerminalView(
                    _session.terminal,
                    key: _terminalKey,
                    controller: _session.controller,
                    focusNode: _focusNode,
                    autofocus: false,
                    // 输入法键盘的输入类型（默认 emailAddress 不合适）。
                    keyboardType: TextInputType.text,
                    textStyle: TerminalStyle(
                      fontSize: fontSize,
                      fontFamily: 'monospace',
                    ),
                    theme: termTheme,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    hardwareKeyboardOnly: false,
                    // 长按：有选区复制，无选区粘贴。
                    onSecondaryTapUp: (details, offset) =>
                        _onClipboardAction(),
                  ),
                  // 有选区时浮出工具条：复制 / 全选 / 粘贴。
                ],
              ),
            ),
            // 虚拟按键条随手机输入法键盘一同显示/消失（输入法弹出时
            // 位于其上方，与 server_box 的 AnimatedPadding(viewInsets) 一致）。
            if (_settings.showVirtKeys && _imeVisible)
              VirtKeysBar(
                inputHandler: _inputHandler,
                onInput: (data) => _session.terminal.textInput(data),
                onKey: (key) => _session.terminal.keyInput(key),
                onToggleIme: _toggleIme,
              ),
          ],
        ),
          ),
          // 悬浮在 AppBar 区域上方，可遮挡标题/按钮，不盖住终端文字
          if (_showCopyBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Center(
                    child: _SelectionToolbar(
                      onCopy: _copySelection,
                      onSelectAll: _selectAll,
                      onPaste: _pasteFromClipboard,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 终端选区浮动工具条：复制 / 全选 / 粘贴。
///
/// pub 版 xterm 无系统文本选择工具条（server_box 用的是其 fork 的
/// `toolbarBuilder`），这里自绘等价体验：有选区时浮在终端顶部。
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.onCopy,
    required this.onSelectAll,
    required this.onPaste,
  });

  final Future<void> Function() onCopy;
  final VoidCallback onSelectAll;
  final Future<void> Function() onPaste;

  @override
  Widget build(BuildContext context) {
    // 白底黑字 + 黑色轮廓，固定在 AppBar 高度，不遮挡终端选区
    return Material(
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Colors.black87, width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarAction(
              icon: Icons.content_copy_outlined,
              label: '复制',
              emphasized: true,
              onTap: onCopy,
            ),
            _ToolbarAction(
              icon: Icons.select_all_outlined,
              label: '全选',
              onTap: onSelectAll,
            ),
            _ToolbarAction(
              icon: Icons.content_paste_outlined,
              label: '粘贴',
              onTap: onPaste,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final color = emphasized ? Colors.black : Colors.black87;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _darkTheme = TerminalTheme(
  cursor: const Color(0xFFAEAFAD),
  selection: const Color(0x40FFFFFF),
  foreground: const Color(0xFFCCCCCC),
  background: const Color(0xFF1E1E1E),
  black: const Color(0xFF000000),
  red: const Color(0xFFCD3131),
  green: const Color(0xFF0DBC79),
  yellow: const Color(0xFFE5E510),
  blue: const Color(0xFF2472C8),
  magenta: const Color(0xFFBC3FBC),
  cyan: const Color(0xFF11A8CD),
  white: const Color(0xFFE5E5E5),
  brightBlack: const Color(0xFF666666),
  brightRed: const Color(0xFFF14C4C),
  brightGreen: const Color(0xFF23D18B),
  brightYellow: const Color(0xFFF5F543),
  brightBlue: const Color(0xFF3B8EEA),
  brightMagenta: const Color(0xFFD670D6),
  brightCyan: const Color(0xFF29B8DB),
  brightWhite: const Color(0xFFE5E5E5),
  searchHitBackground: const Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: const Color(0xFF31FF26),
  searchHitForeground: const Color(0xFF000000),
);

final _lightTheme = TerminalTheme(
  cursor: const Color(0xFF000000),
  selection: const Color(0x40000000),
  foreground: const Color(0xFF333333),
  background: const Color(0xFFFAFAFA),
  black: const Color(0xFF000000),
  red: const Color(0xFFCD3131),
  green: const Color(0xFF00BC00),
  yellow: const Color(0xFF949800),
  blue: const Color(0xFF0451A5),
  magenta: const Color(0xFFBC05BC),
  cyan: const Color(0xFF0598BC),
  white: const Color(0xFF555555),
  brightBlack: const Color(0xFF666666),
  brightRed: const Color(0xFFCD3131),
  brightGreen: const Color(0xFF14CE14),
  brightYellow: const Color(0xFFB5B00),
  brightBlue: const Color(0xFF0451A5),
  brightMagenta: const Color(0xFFBC05BC),
  brightCyan: const Color(0xFF0598BC),
  brightWhite: const Color(0xFFA5A5A5),
  searchHitBackground: const Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: const Color(0xFF31FF26),
  searchHitForeground: const Color(0xFF000000),
);
