/// 远程文件/目录条目（SFTP 与命令模式共用，UI 不依赖 dartssh2 的 SftpName）。
class RemoteFileEntry {
  const RemoteFileEntry({
    required this.filename,
    required this.isDirectory,
    this.size,
    this.modifyTime,
    this.longname = '',
  });

  final String filename;
  final bool isDirectory;
  final int? size;

  /// Unix 秒时间戳（可选）。
  final int? modifyTime;

  /// 原始 longname / ls 行（调试用）。
  final String longname;

  bool get isDotDot => filename == '..';
}
