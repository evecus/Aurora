import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aurora/models/remote_file_entry.dart';
import 'package:aurora/models/server.dart';
import 'package:aurora/pages/sftp_edit_page.dart';
import 'package:aurora/services/sftp_session.dart';

/// SFTP 文件列表页（交互参考 ServerBox 文件浏览器，精简实现）。
class SftpPage extends StatefulWidget {
  const SftpPage({super.key, required this.server});

  final Server server;

  @override
  State<SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends State<SftpPage> {
  late final SftpSession _session;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _session = SftpSession(server: widget.server);
    _session.stateNotifier.addListener(_onChanged);
    _session.entries.addListener(_onChanged);
    _session.loading.addListener(_onChanged);
    _session.modeNotifier.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.connect();
    });
  }

  @override
  void dispose() {
    _session.stateNotifier.removeListener(_onChanged);
    _session.entries.removeListener(_onChanged);
    _session.loading.removeListener(_onChanged);
    _session.modeNotifier.removeListener(_onChanged);
    _session.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openEntry(RemoteFileEntry entry) async {
    if (entry.filename == '..') {
      await _run(() => _session.cd('..'));
      return;
    }
    if (entry.isDirectory) {
      await _run(() => _session.cd(entry.filename));
      return;
    }
    // 点文件 → 编辑（同 ServerBox）
    await _edit(entry);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _mkdir() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _run(() => _session.mkdir(name));
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「${entry.filename}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _session.remove(entry));
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final controller = TextEditingController(text: entry.filename);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == entry.filename) return;
    await _run(() => _session.rename(entry.filename, name));
  }

  Future<void> _download(RemoteFileEntry entry) async {
    try {
      final data = await _session.readFile(entry.filename);
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/aurora_downloads');
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }
      final file = File('${folder.path}/${entry.filename}');
      await file.writeAsBytes(data);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存到 ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败: $e')),
      );
    }
  }

  Future<void> _edit(RemoteFileEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SftpEditPage(
          session: _session,
          fileName: entry.filename,
        ),
      ),
    );
    // 保存后刷新列表
    if (mounted) await _run(_session.refresh);
  }

  /// 从系统选择文件上传到当前目录（参考 ServerBox 系统文件选择）。
  Future<void> _upload() async {
    if (_uploading) return;

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _uploading = true);
    var okCount = 0;
    var failCount = 0;

    try {
      for (final f in result.files) {
        final name = f.name;
        if (name.isEmpty) continue;

        Uint8List? bytes = f.bytes;
        if (bytes == null && f.path != null) {
          bytes = await File(f.path!).readAsBytes();
        }
        if (bytes == null) {
          failCount++;
          continue;
        }

        try {
          await _session.writeFile(name, bytes);
          okCount++;
        } catch (_) {
          failCount++;
        }
      }

      if (!mounted) return;
      final msg = failCount == 0
          ? '已上传 $okCount 个文件'
          : '成功 $okCount，失败 $failCount';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      await _session.refresh();
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showEntrySheet(RemoteFileEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                entry.isDirectory
                    ? Icons.folder
                    : Icons.insert_drive_file_outlined,
                color: scheme.primary,
              ),
              title: Text(entry.filename),
              subtitle: Text(_entrySubtitle(entry)),
            ),
            const Divider(height: 1),
            if (!entry.isDirectory) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                onTap: () {
                  Navigator.pop(ctx);
                  _edit(entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载到本机'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(entry);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(entry);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text('删除', style: TextStyle(color: scheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(entry);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _entrySubtitle(RemoteFileEntry entry) {
    final parts = <String>[];
    if (entry.isDirectory) {
      parts.add('文件夹');
    } else {
      parts.add(_formatSize(entry.size));
    }
    final m = entry.modifyTime;
    if (m != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(m * 1000);
      parts.add(
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
      );
    }
    return parts.join(' · ');
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = _session.currentPath;
    final entries = _session.entries.value;
    final loading = _session.loading.value || _uploading;
    final state = _session.state;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.server.name, style: const TextStyle(fontSize: 16)),
            Text(
              _session.mode == FileTransferMode.command
                  ? '$path  ·  兼容模式'
                  : path,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '上级目录',
            icon: const Icon(Icons.arrow_upward),
            onPressed: state == SftpState.ready && path != '/'
                ? () => _run(() => _session.cd('..'))
                : null,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed:
                state == SftpState.ready ? () => _run(_session.refresh) : null,
          ),
          IconButton(
            tooltip: '上传文件',
            icon: _uploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file),
            onPressed: state == SftpState.ready && !_uploading ? _upload : null,
          ),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: state == SftpState.ready ? _mkdir : null,
          ),
        ],
      ),
      body: _buildBody(scheme, state, loading, entries, path),
    );
  }

  Widget _buildBody(
    ColorScheme scheme,
    SftpState state,
    bool loading,
    List<RemoteFileEntry> entries,
    String path,
  ) {
    if (state == SftpState.connecting) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state == SftpState.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 56, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                _session.errorMessage ?? '文件服务连接失败',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _session.connect(),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 2),
        _PathBar(
          path: path,
          onTapSegment: (p) => _run(() => _session.list(p)),
        ),
        Expanded(
          child: entries.isEmpty && !loading
              ? Center(
                  child: Text(
                    '空目录',
                    style: TextStyle(color: scheme.outline),
                  ),
                )
              : ListView.separated(
                  itemCount: entries.length + (path != '/' ? 1 : 0),
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (path != '/' && index == 0) {
                      return ListTile(
                        leading: Icon(Icons.folder, color: scheme.primary),
                        title: const Text('..'),
                        subtitle: const Text('返回上级'),
                        onTap: () => _run(() => _session.cd('..')),
                      );
                    }
                    final entry = entries[path != '/' ? index - 1 : index];
                    if (entry.filename == '..') {
                      return const SizedBox.shrink();
                    }
                    final isDir = entry.isDirectory;
                    return ListTile(
                      leading: Icon(
                        isDir
                            ? Icons.folder
                            : Icons.insert_drive_file_outlined,
                        color: isDir ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      title: Text(entry.filename),
                      subtitle: Text(_entrySubtitle(entry)),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => _showEntrySheet(entry),
                      ),
                      onTap: () => _openEntry(entry),
                      onLongPress: () => _showEntrySheet(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({required this.path, required this.onTapSegment});

  final String path;
  final void Function(String path) onTapSegment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = path == '/'
        ? <String>[]
        : path.split('/').where((e) => e.isNotEmpty).toList();

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.home_outlined, size: 16),
              label: const Text('/'),
              onPressed: () => onTapSegment('/'),
            ),
            for (var i = 0; i < parts.length; i++) ...[
              Icon(Icons.chevron_right, size: 16, color: scheme.outline),
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(parts[i]),
                onPressed: () {
                  final p = '/${parts.sublist(0, i + 1).join('/')}';
                  onTapSegment(p);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
