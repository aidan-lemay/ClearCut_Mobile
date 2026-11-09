import 'dart:convert';
import 'dart:typed_data';

import 'package:clearcut_core/call_utils.dart';
import 'package:clearcut_mobile/services/notifications.dart';

export 'package:clearcut_core/call_utils.dart' show isValidSystemId;
import 'package:file_picker/file_picker.dart';

/// Backup files are JSON, marked with this format name and a kind, so that a
/// favorites file can't be loaded as settings or the other way round.
const backupFormat = 'clearcut_mobile';

/// Bump when the file layout changes in a way older versions can't read.
const backupVersion = 1;

const favoritesBackupKind = 'favorites';
const settingsBackupKind = 'settings';

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
    throw BackupException(kind == favoritesBackupKind
        ? 'This is a settings backup. Use Import Settings for it.'
        : 'This is a favorites backup. Use Import Favorites for it.');
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
  SettingsBackup(
      {required this.hiddenSystems, NotificationBackup? notifications})
      : notifications = notifications ?? NotificationBackup();
}

/// [notifications] is the relay address and alert rules. The access key is
/// never part of a backup.
String exportSettings({
  required List<Map<String, dynamic>> hiddenSystems,
  Map<String, dynamic>? notifications,
}) =>
    _encode(settingsBackupKind, {
      'settings': {
        'hiddenSystems': hiddenSystems,
        if (notifications != null) 'notifications': notifications,
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
  return SettingsBackup(
      hiddenSystems: hiddenSystems, notifications: notifications);
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
