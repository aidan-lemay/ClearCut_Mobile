import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clearcut_core/call_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// What an alert rule notifies about. Names match the relay's.
enum AlertMode {
  all('Every call'),
  transcripts('Every transcript'),
  keywords('Transcripts with keywords');

  final String label;
  const AlertMode(this.label);
}

/// One alert rule, sent to the relay as is. The relay ignores the fields it
/// doesn't use, like [systemName].
class AlertRule {
  final String id;
  final String name;
  final bool enabled;
  final String systemId;
  final String systemName;

  /// Each `{'id': int, 'name': String}`.
  final List<Map<String, dynamic>> talkgroups;
  final AlertMode mode;
  final List<String> keywords;

  AlertRule({
    String? id,
    required this.name,
    this.enabled = true,
    required this.systemId,
    required this.systemName,
    required this.talkgroups,
    required this.mode,
    this.keywords = const [],
  }) : id = id ?? newId('r');

  AlertRule copyWith({bool? enabled}) => AlertRule(
        id: id,
        name: name,
        enabled: enabled ?? this.enabled,
        systemId: systemId,
        systemName: systemName,
        talkgroups: talkgroups,
        mode: mode,
        keywords: keywords,
      );

  /// Throws [FormatException] if [json] isn't a rule.
  factory AlertRule.fromJson(Object? json) {
    final bad = FormatException('Damaged alert rule.');
    if (json is! Map ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['systemId'] is! String ||
        !isValidSystemId(json['systemId']) ||
        json['talkgroups'] is! List) {
      throw bad;
    }
    final mode = AlertMode.values.asNameMap()[json['mode']];
    if (mode == null) throw bad;
    final talkgroups = <Map<String, dynamic>>[];
    for (final tg in json['talkgroups']) {
      if (tg is! Map || tg['id'] is! int) throw bad;
      talkgroups.add({
        'id': tg['id'],
        'name': tg['name'] is String ? tg['name'] : 'Talkgroup ${tg['id']}',
      });
    }
    final keywords = json['keywords'];
    return AlertRule(
      id: json['id'],
      name: json['name'],
      enabled: json['enabled'] != false,
      systemId: json['systemId'],
      systemName:
          json['systemName'] is String ? json['systemName'] : json['systemId'],
      talkgroups: talkgroups,
      mode: mode,
      keywords: keywords is List ? keywords.whereType<String>().toList() : [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'systemId': systemId,
        'systemName': systemName,
        'talkgroups': talkgroups,
        'mode': mode.name,
        'keywords': keywords,
      };

  /// A line describing the rule, for lists.
  String get summary {
    final count = talkgroups.length == 1
        ? talkgroups.single['name']
        : '${talkgroups.length} talkgroups';
    final what = mode == AlertMode.keywords
        ? 'Keywords: ${keywords.join(', ')}'
        : mode.label;
    return '$what · $count on $systemName';
  }
}

String newId(String prefix) {
  final random = Random.secure();
  final bytes = List.generate(18, (_) => random.nextInt(256));
  return '$prefix${base64Url.encode(bytes).replaceAll('=', '')}';
}

/// Splits what was typed into the keywords box: comma separated, blanks
/// dropped, duplicates removed.
List<String> parseKeywords(String text) {
  final seen = <String>{};
  return [
    for (final part in text.split(','))
      if (part.trim().replaceAll('*', '').isNotEmpty &&
          seen.add(part.trim().toLowerCase()))
        part.trim()
  ];
}

/// The relay's address. Addresses without a scheme use HTTPS, so the access
/// key isn't sent in the clear unless `http://` is typed on purpose.
Uri? relayBaseUri(String address, int? port) {
  var text = address.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: port ?? (uri.hasPort ? uri.port : null),
    path: path,
  );
}

/// A problem talking to the relay. [message] is written for the user.
class RelayException implements Exception {
  final String message;
  RelayException(this.message);

  @override
  String toString() => message;
}

class RelayStatus {
  final String keyName;

  /// 'fcm' when the relay can really send pushes.
  final String push;
  RelayStatus({required this.keyName, required this.push});

  bool get canPush => push == 'fcm';
}

class RelayClient {
  static const timeout = Duration(seconds: 15);

  final Uri base;
  final String key;
  RelayClient(this.base, this.key);

  Future<Map<String, dynamic>> _request(String method, String path,
      [Object? body]) async {
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers['Authorization'] = 'Bearer $key';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final client = http.Client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(
          await client.send(request).timeout(timeout));
    } on TimeoutException {
      throw RelayException("The relay at ${base.host} didn't answer in time.");
    } on HandshakeException {
      throw RelayException("Couldn't make a secure connection to "
          '${base.host}. If the relay has no HTTPS, enter its address '
          'starting with http://.');
    } catch (error) {
      throw RelayException("Couldn't reach a relay at ${base.host}"
          '${base.hasPort ? ':${base.port}' : ''}. Check the address and '
          'port.');
    } finally {
      client.close();
    }

    Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      json = null;
    }
    if (json is! Map<String, dynamic>) {
      throw RelayException(
          "That address doesn't look like a Clearcut relay (it returned "
          '${response.statusCode}).');
    }
    if (response.statusCode == 401) {
      throw RelayException("The relay didn't accept this access key.");
    }
    if (response.statusCode >= 400) {
      throw RelayException(json['error'] is String
          ? json['error']
          : 'The relay returned an error (${response.statusCode}).');
    }
    return json;
  }

  Future<RelayStatus> status() async {
    final json = await _request('GET', '/v1/status');
    if (json['apiVersion'] is! int) {
      throw RelayException("That address doesn't look like a Clearcut relay.");
    }
    return RelayStatus(
      keyName: json['keyName'] as String? ?? '',
      push: json['push'] as String? ?? '',
    );
  }

  Future<void> putDevice(String deviceId, Map<String, dynamic> setup) =>
      _request('PUT', '/v1/devices/$deviceId', setup);

  Future<void> deleteDevice(String deviceId) =>
      _request('DELETE', '/v1/devices/$deviceId');

  Future<void> sendTest(String deviceId) =>
      _request('POST', '/v1/devices/$deviceId/test');
}

/// Where push tokens and incoming pushes come from. Firebase in the app, a
/// fake in tests.
abstract class PushService {
  /// False when this build has no Firebase setup.
  bool get available;
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;

  /// Pushes that arrive while the app is open.
  Stream<Map<String, String>> get onMessage;
  Future<bool> requestPermission();
}

class NoPushService implements PushService {
  const NoPushService();

  @override
  bool get available => false;
  @override
  Future<String?> getToken() async => null;
  @override
  Stream<String> get onTokenRefresh => Stream.empty();
  @override
  Stream<Map<String, String>> get onMessage => Stream.empty();
  @override
  Future<bool> requestPermission() async => false;
}

const notificationPrefsKey = 'notifications';

/// Whether a push should be shown, read straight from storage, for the
/// background handler, which runs without the rest of the app.
Future<bool> alertsAllowedFromStorage() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final stored = prefs.getString(notificationPrefsKey);
  if (stored == null) return false;
  final json = jsonDecode(stored) as Map<String, dynamic>;
  return json['subscribed'] == true && !_isPaused(json);
}

/// The saved alert rules, for the background handler.
Future<List<AlertRule>> rulesFromStorage() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(notificationPrefsKey);
  if (stored == null) return [];
  final json = jsonDecode(stored) as Map<String, dynamic>;
  return [
    for (final rule in json['rules'] as List? ?? []) AlertRule.fromJson(rule)
  ];
}

bool _isPaused(Map<String, dynamic> json) {
  if (json['paused'] != true) return false;
  final until = json['pausedUntil'];
  return until is! int || DateTime.now().millisecondsSinceEpoch < until * 1000;
}

/// The phone's notification setup, saved locally and mirrored to the relay.
class NotificationController extends ChangeNotifier {
  final PushService push;

  /// Shows a push that arrived while the app is open.
  final void Function(Map<String, String> data)? showAlert;

  /// Keeps each rule's Android notification category up to date.
  final void Function(List<AlertRule> rules)? onRulesChanged;

  NotificationController(this.push, {this.showAlert, this.onRulesChanged});

  String address = '';
  int? port;
  String key = '';
  bool subscribed = false;
  bool paused = false;
  DateTime? pausedUntil;
  List<AlertRule> rules = [];
  String deviceId = '';

  RelayStatus? status;
  bool syncing = false;
  String? syncError;
  bool _syncAgain = false;
  final _subscriptions = <StreamSubscription>[];

  bool get isPaused => _isPaused(_pauseJson());

  bool get isConfigured =>
      relayBaseUri(address, port) != null && key.isNotEmpty;

  bool get usesPlainHttp => relayBaseUri(address, port)?.scheme == 'http';

  RelayClient? get _client {
    final base = relayBaseUri(address, port);
    return base == null || key.isEmpty ? null : RelayClient(base, key);
  }

  Map<String, dynamic> _pauseJson() => {
        'paused': paused,
        'pausedUntil': pausedUntil == null
            ? null
            : pausedUntil!.millisecondsSinceEpoch ~/ 1000,
      };

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('deviceId') ?? '';
      if (deviceId.isEmpty) {
        deviceId = newId('d');
        await prefs.setString('deviceId', deviceId);
      }
      final stored = prefs.getString(notificationPrefsKey);
      if (stored != null) {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        address = json['address'] as String? ?? '';
        port = json['port'] as int?;
        key = json['key'] as String? ?? '';
        subscribed = json['subscribed'] == true;
        paused = json['paused'] == true;
        final until = json['pausedUntil'];
        pausedUntil = until is int
            ? DateTime.fromMillisecondsSinceEpoch(until * 1000)
            : null;
        rules = [
          for (final rule in json['rules'] as List? ?? [])
            AlertRule.fromJson(rule)
        ];
      }
    } catch (error) {
      print('Error loading notification settings: $error');
    }
    notifyListeners();
    onRulesChanged?.call(rules);

    _subscriptions.add(push.onTokenRefresh.listen((_) => sync()));
    _subscriptions.add(push.onMessage.listen((data) {
      if (subscribed && !isPaused) showAlert?.call(data);
    }));
    // Catches up on changes the relay missed, and refreshes the push token,
    // which Firebase can change while the app is closed.
    if (subscribed) unawaited(sync());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          notificationPrefsKey,
          jsonEncode({
            'address': address,
            'port': port,
            'key': key,
            'subscribed': subscribed,
            ..._pauseJson(),
            'rules': [for (final rule in rules) rule.toJson()],
          }));
    } catch (error) {
      print('Error saving notification settings: $error');
    }
  }

  Future<void> _changed() async {
    await _save();
    notifyListeners();
    onRulesChanged?.call(rules);
    if (subscribed) await sync();
  }

  /// Checks the relay and key, then registers this phone. Returns an error
  /// message, or null on success.
  Future<String?> connect(
      String newAddress, int? newPort, String newKey) async {
    final base = relayBaseUri(newAddress, newPort);
    if (base == null) {
      return 'Enter the relay\'s address, like relay.example.com.';
    }
    if (newKey.trim().isEmpty) return 'Enter your access key.';
    if (!push.available) {
      return 'This copy of the app was built without push support.';
    }

    try {
      status = await RelayClient(base, newKey.trim()).status();
    } on RelayException catch (error) {
      return error.message;
    }

    // A phone is registered under one key, so a different key or relay means
    // registering again as a new device, after removing the old one.
    final previous = _client;
    if (previous != null &&
        (previous.key != newKey.trim() || previous.base != base)) {
      if (subscribed) {
        try {
          await previous.deleteDevice(deviceId);
        } on RelayException catch (error) {
          print('Couldn\'t remove the old registration: $error');
        }
      }
      deviceId = newId('d');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('deviceId', deviceId);
      } catch (error) {
        print('Error saving device ID: $error');
      }
    }

    address = newAddress.trim();
    port = newPort;
    key = newKey.trim();
    subscribed = true;
    await push.requestPermission();
    await _save();
    notifyListeners();
    return sync();
  }

  /// Sends the whole setup to the relay. Returns an error message, or null on
  /// success. Overlapping calls are merged into one more sync.
  Future<String?> sync() async {
    final client = _client;
    if (!subscribed || client == null) return null;
    if (syncing) {
      _syncAgain = true;
      return null;
    }
    syncing = true;
    notifyListeners();

    String? error;
    do {
      _syncAgain = false;
      try {
        final token = await push.getToken();
        if (token == null) {
          throw RelayException("Couldn't get a push token from Google Play "
              'services.');
        }
        await client.putDevice(deviceId, {
          'token': token,
          'rules': [for (final rule in rules) rule.toJson()],
          ..._pauseJson(),
        });
        status ??= await client.status();
        error = null;
      } on RelayException catch (e) {
        error = e.message;
      } catch (e) {
        error = 'Couldn\'t update the relay: $e';
      }
    } while (_syncAgain);

    syncing = false;
    syncError = error;
    notifyListeners();
    return error;
  }

  /// Removes this phone from the relay and stops showing alerts. Returns a
  /// warning if the relay couldn't be told, though alerts stop either way.
  Future<String?> unsubscribe() async {
    final client = _client;
    subscribed = false;
    syncError = null;
    status = null;
    await _save();
    notifyListeners();
    try {
      await client?.deleteDevice(deviceId);
      return null;
    } on RelayException catch (error) {
      return 'Notifications are off on this phone, but the relay couldn\'t '
          'be told: ${error.message}';
    }
  }

  /// Pauses for [duration], or until [resume] if null.
  Future<void> pause(Duration? duration) async {
    paused = true;
    pausedUntil = duration == null ? null : DateTime.now().add(duration);
    await _changed();
  }

  Future<void> resume() async {
    paused = false;
    pausedUntil = null;
    await _changed();
  }

  Future<void> saveRule(AlertRule rule) async {
    final index = rules.indexWhere((existing) => existing.id == rule.id);
    rules = [...rules];
    if (index < 0) {
      rules.add(rule);
    } else {
      rules[index] = rule;
    }
    await _changed();
  }

  Future<void> deleteRule(String id) async {
    rules = rules.where((rule) => rule.id != id).toList();
    await _changed();
  }

  /// Returns an error message, or null if the relay sent the test.
  Future<String?> sendTest() async {
    final client = _client;
    if (client == null) return 'Set up a relay first.';
    try {
      await client.sendTest(deviceId);
      return null;
    } on RelayException catch (error) {
      return error.message;
    }
  }

  /// For settings backups. The access key is left out on purpose: a backup
  /// file is easy to share by mistake.
  Map<String, dynamic> toBackupJson() => {
        'address': address,
        'port': port,
        'rules': [for (final rule in rules) rule.toJson()],
      };

  /// Imports a backup's server and rules. Adding keeps the current server if
  /// there is one and skips rules already present. Returns how many rules
  /// were added.
  Future<int> importBackup(NotificationBackup backup,
      {required bool replace}) async {
    if (replace || address.isEmpty) {
      if (backup.address.isNotEmpty) {
        address = backup.address;
        port = backup.port;
      }
    }
    if (replace) rules = [];
    final ids = rules.map((rule) => rule.id).toSet();
    final added = [
      for (final rule in backup.rules)
        if (ids.add(rule.id)) rule
    ];
    rules = [...rules, ...added];
    await _changed();
    return added.length;
  }
}

/// The notification part of a settings backup.
class NotificationBackup {
  final String address;
  final int? port;
  final List<AlertRule> rules;
  NotificationBackup({this.address = '', this.port, this.rules = const []});

  /// Throws [FormatException] if [json] is damaged.
  factory NotificationBackup.fromJson(Object? json) {
    if (json == null) return NotificationBackup();
    if (json is! Map) throw FormatException('Damaged notification settings.');
    final address = json['address'];
    final port = json['port'];
    final rules = json['rules'] ?? [];
    if ((address != null && address is! String) ||
        (port != null && port is! int) ||
        rules is! List) {
      throw FormatException('Damaged notification settings.');
    }
    return NotificationBackup(
      address: address ?? '',
      port: port,
      rules: [for (final rule in rules) AlertRule.fromJson(rule)],
    );
  }
}

/// A stable small number for a string, for notification IDs. String.hashCode
/// isn't guaranteed to match between the app and its background handler.
int stableNotificationId(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

@visibleForTesting
bool isPausedJson(Map<String, dynamic> json) => _isPaused(json);
