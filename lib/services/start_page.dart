import 'dart:convert';

import 'package:clearcut_core/call_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum StartPageKind { systems, favorites, system, talkgroups }

/// The page the app opens on. Systems is always underneath, so Back from the
/// start page leads there.
///
/// A favorite is kept as its talkgroups rather than a link to the favorite,
/// so the start page keeps working if the favorite is later removed.
class StartPage {
  final StartPageKind kind;
  final String systemId;
  final String systemName;

  /// For [StartPageKind.talkgroups]: each is `{'id': ..., 'name': ...}`.
  final List<Map<String, dynamic>> talkgroups;

  const StartPage._(this.kind,
      {this.systemId = '', this.systemName = '', this.talkgroups = const []});

  static const systems = StartPage._(StartPageKind.systems);
  static const favorites = StartPage._(StartPageKind.favorites);

  StartPage.system(String id, String name)
      : this._(StartPageKind.system, systemId: id, systemName: name);

  StartPage.talkgroups(String systemId, String systemName,
      List<dynamic> talkgroups)
      : this._(
          StartPageKind.talkgroups,
          systemId: systemId,
          systemName: systemName,
          talkgroups: [
            for (final tg in talkgroups) {'id': tg['id'], 'name': tg['name']}
          ],
        );

  /// For listing in Settings, e.g. `Dispatch, Fire (Monroe County)`.
  String get description => switch (kind) {
        StartPageKind.systems => 'Systems',
        StartPageKind.favorites => 'Favorites',
        StartPageKind.system => systemName,
        StartPageKind.talkgroups =>
          '${talkgroups.map((tg) => tg['name']).join(', ')} ($systemName)',
      };

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (systemId.isNotEmpty) 'systemId': systemId,
        if (systemName.isNotEmpty) 'systemName': systemName,
        if (talkgroups.isNotEmpty) 'talkgroups': talkgroups,
      };

  /// Falls back to [systems] if [json] is damaged, so a bad setting can never
  /// stop the app opening.
  factory StartPage.fromJson(Object? json) {
    if (json is! Map) return systems;
    final kind = StartPageKind.values.asNameMap()[json['kind']];
    final systemId = json['systemId'];
    final name = json['systemName'];
    final systemName = name is String && name.isNotEmpty ? name : systemId;
    switch (kind) {
      case StartPageKind.favorites:
        return favorites;
      case StartPageKind.system || StartPageKind.talkgroups
          when systemId is String && isValidSystemId(systemId):
        if (kind == StartPageKind.system) {
          return StartPage.system(systemId, systemName);
        }
        final list = json['talkgroups'];
        if (list is! List || list.isEmpty) return systems;
        final talkgroups = <Map<String, dynamic>>[];
        for (final tg in list) {
          if (tg is! Map || tg['id'] is! int) return systems;
          talkgroups.add({
            'id': tg['id'],
            'name': tg['name'] is String ? tg['name'] : 'Talkgroup ${tg['id']}',
          });
        }
        return StartPage.talkgroups(systemId, systemName, talkgroups);
      default:
        return systems;
    }
  }

  static const _prefsKey = 'startPage';

  static Future<StartPage> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      return stored == null ? systems : StartPage.fromJson(jsonDecode(stored));
    } catch (error) {
      print('Error loading start page: $error');
      return systems;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(toJson()));
    } catch (error) {
      print('Error saving start page: $error');
    }
  }
}
