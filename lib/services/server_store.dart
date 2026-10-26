import 'package:shared_preferences/shared_preferences.dart';
import 'package:aurora/models/server.dart';
import 'package:uuid/uuid.dart';

/// 本地持久化服务器列表。
class ServerStore {
  ServerStore._();
  static final ServerStore instance = ServerStore._();

  static const _key = 'servers_v1';
  final _uuid = const Uuid();

  List<Server> _servers = [];
  List<Server> get servers => List.unmodifiable(_servers);

  final List<void Function()> _listeners = [];

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);
  void _notify() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        _servers = Server.decodeList(raw);
      } catch (_) {
        _servers = [];
      }
    }
    _notify();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, Server.encodeList(_servers));
    _notify();
  }

  Future<Server> add({
    required String name,
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    String? passphrase,
  }) async {
    final s = Server(
      id: _uuid.v4(),
      name: name,
      host: host,
      port: port,
      username: username,
      password: password,
      privateKey: privateKey,
      passphrase: passphrase,
    );
    _servers = [..._servers, s];
    await _save();
    return s;
  }

  Future<void> update(Server server) async {
    final i = _servers.indexWhere((e) => e.id == server.id);
    if (i < 0) return;
    _servers = [..._servers]..[i] = server;
    await _save();
  }

  Future<void> remove(String id) async {
    _servers = _servers.where((e) => e.id != id).toList();
    await _save();
  }

  Server? byId(String id) {
    try {
      return _servers.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }
}
