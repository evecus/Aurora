import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/services/server_store.dart';
import 'package:aurora/pages/terminal_page.dart';
import 'package:uuid/uuid.dart';

class ServerEditPage extends StatefulWidget {
  const ServerEditPage({super.key, this.server});

  /// null = 新建
  final Server? server;

  @override
  State<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends State<ServerEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;

  bool _obscurePassword = true;
  bool _useKey = false;
  bool _saving = false;

  bool get _isEdit => widget.server != null;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _name = TextEditingController(text: s?.name ?? '');
    _host = TextEditingController(text: s?.host ?? '');
    _port = TextEditingController(text: '${s?.port ?? 22}');
    _username = TextEditingController(text: s?.username ?? 'root');
    _password = TextEditingController(text: s?.password ?? '');
    _privateKey = TextEditingController(text: s?.privateKey ?? '');
    _passphrase = TextEditingController(text: s?.passphrase ?? '');
    _useKey = (s?.privateKey != null && s!.privateKey!.isNotEmpty);
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      final port = int.tryParse(_port.text.trim()) ?? 22;
      final name = _name.text.trim().isEmpty
          ? _host.text.trim()
          : _name.text.trim();

      if (_isEdit) {
        final updated = widget.server!.copyWith(
          name: name,
          host: _host.text.trim(),
          port: port,
          username: _username.text.trim(),
          password: _useKey ? null : _password.text,
          privateKey: _useKey ? _privateKey.text.trim() : null,
          passphrase:
              _useKey && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        );
        // clear the other auth method
        if (_useKey) {
          updated.password = null;
        } else {
          updated.privateKey = null;
          updated.passphrase = null;
        }
        await ServerStore.instance.update(updated);
        if (mounted) Navigator.of(context).pop(updated);
      } else {
        final created = await ServerStore.instance.add(
          name: name,
          host: _host.text.trim(),
          port: port,
          username: _username.text.trim(),
          password: _useKey ? null : _password.text,
          privateKey: _useKey ? _privateKey.text.trim() : null,
          passphrase:
              _useKey && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        );
        if (mounted) Navigator.of(context).pop(created);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 快速连接：不写入服务器列表，直接打开终端。
  Future<void> _connectQuick() async {
    if (!_formKey.currentState!.validate()) return;

    final port = int.tryParse(_port.text.trim()) ?? 22;
    final host = _host.text.trim();
    final name = _name.text.trim().isEmpty ? host : _name.text.trim();

    final temp = Server(
      id: const Uuid().v4(),
      name: name,
      host: host,
      port: port,
      username: _username.text.trim(),
      password: _useKey ? null : _password.text,
      privateKey: _useKey ? _privateKey.text.trim() : null,
      passphrase:
          _useKey && _passphrase.text.isNotEmpty ? _passphrase.text : null,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalPage(server: temp),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '服务器编辑' : '连接添加'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                hintText: '默认使用主机名',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: '主机 *',
                hintText: 'IP 或域名',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入主机' : null,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(
                labelText: '端口',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: '用户名 *',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 20),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('密码'), icon: Icon(Icons.password)),
                ButtonSegment(value: true, label: Text('私钥'), icon: Icon(Icons.key)),
              ],
              selected: {_useKey},
              onSelectionChanged: (s) => setState(() => _useKey = s.first),
            ),
            const SizedBox(height: 16),
            if (!_useKey) ...[
              TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: '密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
            ] else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '私钥 (PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                validator: (v) {
                  if (_useKey && (v == null || v.trim().isEmpty)) {
                    return '请粘贴私钥';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '私钥密码（如有）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (_isEdit)
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存修改'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _connectQuick,
                      icon: const Icon(Icons.terminal),
                      label: const Text('连接'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('添加服务器'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
