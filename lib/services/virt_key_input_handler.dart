import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// 虚拟修饰键（Ctrl / Alt / Shift）输入处理器。
///
/// 逻辑与 server_box 一致：修饰键在虚拟按键条上点选后保持亮起，
/// 之后经 [Terminal.keyInput] 的按键（输入法键盘的字母、物理键盘、
/// 虚拟按键）都会自动带上该修饰键组合。例如点亮 Ctrl 后按输入法
/// 键盘的 c，即发送 Ctrl+C（0x03）。
///
/// 通过 [Terminal.inputHandler] 挂载，事件在交给
/// [defaultInputHandler] 之前把修饰键状态合并进去。
///
/// 继承 [ChangeNotifier]，修饰键状态变化时通知监听者（虚拟按键条），
/// 保证输入法键盘输入后 Ctrl/Alt/Shift 高亮能及时熄灭。
class VirtKeyInputHandler extends ChangeNotifier
    implements TerminalInputHandler {
  VirtKeyInputHandler({this.autoOff = true});

  /// 组合生效一次后自动取消修饰键（对齐 server_box 的
  /// `sshVirtualKeyAutoOff` 设置，默认开启）。
  bool autoOff;

  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;
  bool get shift => _shift;

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void toggleShift() {
    _shift = !_shift;
    notifyListeners();
  }

  bool get anyActive => _ctrl || _alt || _shift;

  /// 取消所有修饰键。
  void resetAll() {
    if (!_ctrl && !_alt && !_shift) return;
    _ctrl = false;
    _alt = false;
    _shift = false;
    notifyListeners();
  }

  /// 仅取消本次事件中实际生效过的修饰键（server_box 同款逻辑）。
  void reset(TerminalKeyboardEvent e) {
    final nextCtrl = e.ctrl ? false : _ctrl;
    final nextAlt = e.alt ? false : _alt;
    final nextShift = e.shift ? false : _shift;
    if (nextCtrl == _ctrl && nextAlt == _alt && nextShift == _shift) return;
    _ctrl = nextCtrl;
    _alt = nextAlt;
    _shift = nextShift;
    notifyListeners();
  }

  @override
  String? call(TerminalKeyboardEvent event) {
    final e = event.copyWith(
      ctrl: event.ctrl || _ctrl,
      alt: event.alt || _alt,
      shift: event.shift || _shift,
    );
    if (autoOff) reset(e);
    return defaultInputHandler.call(e);
  }
}
