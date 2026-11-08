import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'rules.dart';

/// An access key. Only a hash of the secret is stored, so the key file
/// doesn't give anyone access.
class ApiKey {
  final String id;
  final String name;
  final String hash;
  final DateTime created;

  ApiKey({
    required this.id,
    required this.name,
    required this.hash,
    required this.created,
  });

  factory ApiKey.fromJson(Map<String, dynamic> json) => ApiKey(
    id: json['id'],
    name: json['name'],
    hash: json['hash'],
    created: DateTime.parse(json['created']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'hash': hash,
    'created': created.toUtc().toIso8601String(),
  };
}

/// One phone, registered under an access key.
class Device {
  final String id;
  final String keyId;
  String token;
  List<Rule> rules;

  /// Paused with no [pausedUntil] means paused until the phone resumes.
  bool paused;
  DateTime? pausedUntil;
  DateTime updated;
  DateTime? lastPush;

  Device({
    required this.id,
    required this.keyId,
    required this.token,
    required this.rules,
    this.paused = false,
    this.pausedUntil,
    required this.updated,
    this.lastPush,
  });

  bool isActive(DateTime now) =>
      !paused || (pausedUntil != null && now.isAfter(pausedUntil!));

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    id: json['id'],
    keyId: json['keyId'],
    token: json['token'],
    rules: [for (final rule in json['rules']) Rule.fromJson(rule)],
    paused: json['paused'] ?? false,
    pausedUntil: _date(json['pausedUntil']),
    updated: DateTime.parse(json['updated']),
    lastPush: _date(json['lastPush']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'keyId': keyId,
    'token': token,
    'rules': [for (final rule in rules) rule.toJson()],
    'paused': paused,
    'pausedUntil': pausedUntil?.toUtc().toIso8601String(),
    'updated': updated.toUtc().toIso8601String(),
    'lastPush': lastPush?.toUtc().toIso8601String(),
  };
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.parse(value) : null;

const keyPrefix = 'ccr_';

String hashKey(String secret) => sha256.convert(utf8.encode(secret)).toString();

String _random(int bytes) {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(bytes, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// The relay's data: access keys in `keys.json`, written by the command-line
/// tool, and phones in `devices.json`, written by the server.
class RelayStore {
  final Directory dir;

  RelayStore(this.dir);

  File get keysFile => File('${dir.path}/keys.json');
  File get devicesFile => File('${dir.path}/devices.json');

  List<ApiKey> keys = [];
  DateTime? _keysModified;
  final devices = <String, Device>{};
  Timer? _saveTimer;

  /// Reads `keys.json` if it changed since it was last read, so keys made or
  /// revoked with the command-line tool apply to a running server. Returns
  /// whether the keys changed.
  bool reloadKeys() {
    if (!keysFile.existsSync()) {
      final changed = keys.isNotEmpty;
      keys = [];
      _keysModified = null;
      return changed;
    }
    final modified = keysFile.lastModifiedSync();
    if (modified == _keysModified) return false;
    final stored = jsonDecode(keysFile.readAsStringSync()) as List;
    keys = [for (final key in stored) ApiKey.fromJson(key)];
    _keysModified = modified;
    return true;
  }

  void saveKeys() {
    _writeAtomically(keysFile, keys.map((key) => key.toJson()).toList());
  }

  ApiKey? authenticate(String secret) {
    reloadKeys();
    final hash = hashKey(secret);
    for (final key in keys) {
      if (key.hash == hash) return key;
    }
    return null;
  }

  /// Makes a key and returns it with its secret, which is never stored.
  (ApiKey, String) createKey(String name) {
    reloadKeys();
    if (keys.any((key) => key.name == name)) {
      throw StateError('A key named "$name" already exists.');
    }
    final secret = '$keyPrefix${_random(32)}';
    final key = ApiKey(
      id: _random(6),
      name: name,
      hash: hashKey(secret),
      created: DateTime.now(),
    );
    keys.add(key);
    saveKeys();
    return (key, secret);
  }

  /// Returns false if there's no key with that name.
  bool revokeKey(String name) {
    reloadKeys();
    final before = keys.length;
    keys.removeWhere((key) => key.name == name);
    if (keys.length == before) return false;
    saveKeys();
    return true;
  }

  void loadDevices() {
    devices.clear();
    if (!devicesFile.existsSync()) return;
    for (final json in jsonDecode(devicesFile.readAsStringSync()) as List) {
      final device = Device.fromJson(json);
      devices[device.id] = device;
    }
  }

  /// Drops phones whose key was revoked. Returns whether any were dropped.
  bool removeOrphanedDevices() {
    final keyIds = keys.map((key) => key.id).toSet();
    final before = devices.length;
    devices.removeWhere((_, device) => !keyIds.contains(device.keyId));
    if (devices.length == before) return false;
    scheduleSave();
    return true;
  }

  /// Saves devices shortly, so a burst of changes is written once.
  void scheduleSave() {
    _saveTimer ??= Timer(Duration(seconds: 2), saveDevicesNow);
  }

  void saveDevicesNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _writeAtomically(
      devicesFile,
      devices.values.map((device) => device.toJson()).toList(),
    );
  }

  void _writeAtomically(File file, Object json) {
    dir.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(JsonEncoder.withIndent('  ').convert(json));
    temp.renameSync(file.path);
  }
}
