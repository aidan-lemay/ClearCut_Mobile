import 'dart:convert';
import 'dart:typed_data';

import 'package:clearcut_core/call_utils.dart';
import 'package:clearcut_mobile/services/notifications.dart';
import 'package:clearcut_mobile/services/start_page.dart';

export 'package:clearcut_core/call_utils.dart' show isValidSystemId;
import 'package:file_picker/file_picker.dart';

/// Backup files are JSON, marked with this format name and a kind, so that a
/// favorites file can't be loaded as settings or the other way round.
const backupFormat = 'clearcut_mobile';

/// Bump when the file layout changes in a way older versions can't read.
const backupVersion = 1;

const favoritesBackupKind = 'favorites';
const settingsBackupKind = 'settings';
const alertRulesBackupKind = 'alertRules';

/// What each kind of backup is called, and the button that imports it, for
/// telling the user they picked the wrong kind of file.
const _kindNames = {
  favoritesBackupKind: ('a favorites backup', 'Import Favorites'),
  settingsBackupKind: ('a settings backup', 'Import Settings'),
  alertRulesBackupKind: ('an alert rules backup', 'Import Alert Rules'),
};

/// A backup file that can't be imported. [message] is written for the user.
class BackupException implements Exception {
  final String message;
  BackupException(this.message);

  @override
  String toString() => message;
}

String _encode(String kind, Map<String, dynamic> contents) {
  return JsonEncoder.withIndent('  ').convert({
    'format': backupFormat,
    'kind': kind,
    'version': backupVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    ...contents,
  });
}

Map<String, dynamic> _decode(String text, String kind) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map || decoded['format'] != backupFormat) {
    throw BackupException("This file isn't a Clearcut Mobile backup.");
  }
  if (decoded['kind'] != kind) {
    final other = _kindNames[decoded['kind']];
    throw BackupException(other == null
        ? "This backup can't be imported here."
        : 'This is ${other.$1}. Use ${other.$2} for it.');
  }
  final version = decoded['version'];
  if (version is! int || version > backupVersion) {
    throw BackupException(
        'This backup is from a newer version of the app. Update the app to import it.');
  }
  return Map<String, dynamic>.from(decoded);
}

String exportFavorites(List<Map<String, dynamic>> favorites) =>
    _encode(favoritesBackupKind, {'favorites': favorites});

/// Reads a favorites backup, keeping the order it was saved in.
List<Map<String, dynamic>> parseFavoritesBackup(String text) {
  final list = _decode(text, favoritesBackupKind)['favorites'];
  final damaged = BackupException('The favorites in this file are damaged.');
  if (list is! List) throw damaged;

  final favorites = <Map<String, dynamic>>[];
  for (final favorite in list) {
    if (favorite is! Map ||
        favorite['systemId'] is! String ||
        !isValidSystemId(favorite['systemId']) ||
        favorite['talkgroups'] is! List ||
        (favorite['talkgroups'] as List).isEmpty) {
      throw damaged;
    }
    final talkgroups = <Map<String, dynamic>>[];
    for (final tg in favorite['talkgroups']) {
      if (tg is! Map || tg['id'] is! int) throw damaged;
      talkgroups.add({
        ...Map<String, dynamic>.from(tg),
        if (tg['name'] is! String) 'name': 'Talkgroup ${tg['id']}',
      });
    }
    favorites.add({'systemId': favorite['systemId'], 'talkgroups': talkgroups});
  }
  return favorites;
}

/// Settings read from a backup. Settings the file doesn't mention are left
/// empty rather than failing, so older backups stay importable as settings are
/// added.
class SettingsBackup {
  final List<Map<String, dynamic>> hiddenSystems;
  final NotificationBackup notifications;

  /// Null in backups from before the start page was included.
  final StartPage? startPage;
  SettingsBackup(
      {required this.hiddenSystems,
      NotificationBackup? notifications,
      this.startPage})
      : notifications = notifications ?? NotificationBackup();
}

/// [notifications] is the relay connection, including the access key, so a
/// settings backup should be kept private. Alert rules have their own backup.
String exportSettings({
  required List<Map<String, dynamic>> hiddenSystems,
  Map<String, dynamic>? notifications,
  StartPage? startPage,
}) =>
    _encode(settingsBackupKind, {
      'settings': {
        'hiddenSystems': hiddenSystems,
        if (notifications != null) 'notifications': notifications,
        if (startPage != null) 'startPage': startPage.toJson(),
      },
    });

SettingsBackup parseSettingsBackup(String text) {
  final settings = _decode(text, settingsBackupKind)['settings'];
  final damaged = BackupException('The settings in this file are damaged.');
  if (settings is! Map) throw damaged;

  final hiddenSystems = <Map<String, dynamic>>[];
  final list = settings['hiddenSystems'] ?? [];
  if (list is! List) throw damaged;
  for (final system in list) {
    if (system is! Map ||
        system['id'] is! String ||
        !isValidSystemId(system['id'])) {
      throw damaged;
    }
    final name = system['name'];
    hiddenSystems.add({'id': system['id'], 'name': name is String ? name : ''});
  }
  final NotificationBackup notifications;
  try {
    notifications = NotificationBackup.fromJson(settings['notifications']);
  } on FormatException {
    throw damaged;
  }
  final startPage = settings['startPage'];
  return SettingsBackup(
    hiddenSystems: hiddenSystems,
    notifications: notifications,
    // A damaged start page falls back to Systems rather than failing the
    // whole import.
    startPage: startPage == null ? null : StartPage.fromJson(startPage),
  );
}

/// Alert rules on their own, for sharing rules without the rest of the
/// settings. The relay address and access key aren't included.
String exportAlertRules(List<AlertRule> rules) => _encode(
    alertRulesBackupKind, {'rules': [for (final rule in rules) rule.toJson()]});

List<AlertRule> parseAlertRulesBackup(String text) {
  final rules = _decode(text, alertRulesBackupKind)['rules'];
  final damaged = BackupException('The alert rules in this file are damaged.');
  if (rules is! List) throw damaged;
  try {
    return [for (final rule in rules) AlertRule.fromJson(rule)];
  } on FormatException {
    throw damaged;
  }
}


/// Where backups are saved to and loaded from. Swapped out in tests.
abstract class BackupFiles {
  /// Returns false if the user cancelled.
  Future<bool> save(String fileName, String contents);

  /// Returns null if the user cancelled.
  Future<String?> open();
}

/// Uses the system's file picker, so backups can go to Downloads, a cloud
/// drive, or anywhere else the phone offers.
class DeviceBackupFiles implements BackupFiles {
  const DeviceBackupFiles();

  @override
  Future<bool> save(String fileName, String contents) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(contents)),
      mimeType: 'application/json',
    );
    return uri != null;
  }

  @override
  Future<String?> open() async {
    // Any type: files shared through chat or email often lose their JSON type.
    final file = await FilePicker.pickFile();
    return file?.xFile.readAsString();
  }
}
