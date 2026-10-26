import 'dart:convert';

/// 一台可连接的 SSH 服务器。
class Server {
  final String id;
  String name;
  String host;
  int port;
  String username;
  String? password;
  String? privateKey;
  String? passphrase;

  /// 固定 id，表示本机终端（非 SSH）。
  static const localId = 'local';

  Server({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
  });

  /// 是否为本机终端入口。
  bool get isLocal => id == localId;

  /// 首页展示用的本机终端实例（不持久化）。
  static final local = Server(
    id: localId,
    name: '本机终端',
    host: 'localhost',
    port: 0,
    username: 'local',
  );

  String get displayAddr =>
      isLocal ? '本机' : (port == 22 ? host : '$host:$port');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKey': privateKey,
        'passphrase': passphrase,
      };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['host'] as String,
        host: json['host'] as String,
        port: json['port'] as int? ?? 22,
        username: json['username'] as String? ?? 'root',
        password: json['password'] as String?,
        privateKey: json['privateKey'] as String?,
        passphrase: json['passphrase'] as String?,
      );

  Server copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKey,
    String? passphrase,
  }) =>
      Server(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        privateKey: privateKey ?? this.privateKey,
        passphrase: passphrase ?? this.passphrase,
      );

  static String encodeList(List<Server> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<Server> decodeList(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Server.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
