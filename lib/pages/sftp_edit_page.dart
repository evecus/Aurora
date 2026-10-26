import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:aurora/services/sftp_session.dart';

/// 远程文本文件编辑（参考 ServerBox：拉取 → 编辑 → 写回）。
class SftpEditPage extends StatefulWidget {
  const SftpEditPage({
    super.key,
    required this.session,
    required this.fileName,
  });

  final SftpSession session;
  final String fileName;

  @override
  State<SftpEditPage> createState() => _SftpEditPageState();
}

class _SftpEditPageState extends State<SftpEditPage> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  bool _binary = false;

  static const _maxEditBytes = 2 * 1024 * 1024; // 2 MB

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _binary = false;
    });
    try {
      final data = await widget.session.readFile(widget.fileName);
      if (data.length > _maxEditBytes) {
        setState(() {
          _loading = false;
          _error = '文件过大（>${_maxEditBytes ~/ (1024 * 1024)} MB），不支持在线编辑';
        });
        return;
      }
      // 粗略判断是否二进制
      if (_looksBinary(data)) {
        setState(() {
          _loading = false;
          _binary = true;
          _error = '该文件可能是二进制，无法用文本编辑器打开';
        });
        return;
      }
      _controller.text = utf8.decode(data, allowMalformed: true);
      _dirty = false;
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool _looksBinary(Uint8List data) {
    final sample = data.length > 512 ? data.sublist(0, 512) : data;
    var nulls = 0;
    for (final b in sample) {
      if (b == 0) nulls++;
    }
    return nulls > 2;
  }

  Future<void> _save() async {
    if (_saving || _binary) return;
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_controller.text));
      await widget.session.writeFile(widget.fileName, bytes);
      _dirty = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的更改'),
        content: const Text('离开将丢弃修改，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('离开'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.fileName),
          actions: [
            if (_dirty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Center(
                  child: Text('已修改', style: TextStyle(fontSize: 12)),
                ),
              ),
            IconButton(
              tooltip: '保存',
              onPressed: (_loading || _binary || _error != null) ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (!_binary)
                FilledButton(
                  onPressed: _load,
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(12),
              isCollapsed: false,
            ),
            onChanged: (_) {
              if (!_dirty) setState(() => _dirty = true);
            },
          ),
        ),
      ],
    );
  }
}
