import 'dart:async';
import 'dart:convert';

import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/favorites_page.dart';
import 'package:clearcut_mobile/pages/info_page.dart';
import 'package:clearcut_mobile/pages/listener_page.dart';
import 'package:clearcut_mobile/pages/settings_page.dart';
import 'package:clearcut_mobile/pages/systems_page.dart';
import 'package:clearcut_mobile/services/backup.dart';
import 'package:clearcut_mobile/services/alert_notifications.dart';
import 'package:clearcut_mobile/services/call_utils.dart';
import 'package:clearcut_mobile/services/notifications.dart';
import 'package:clearcut_mobile/services/sse_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> call(String id, int start, {Object? transcript}) => {
      'id': id,
      'talkgroup': 1,
      'startTime': start,
      'endTime': start + 2,
      'audioFile': 'audio/sys/1/$id.m4a',
      'transcript': transcript,
    };

Map<String, dynamic> talkgroup(int id, String name) => {
      'id': id,
      'name': name,
      'description': '$name description',
      'transcribe': true,
    };

/// A fake API. Counts requests per path, and leaves the stream open until the
/// test closes it.
class FakeApi {
  final requests = <String, int>{};
  final calls = <http.Request>[];
  var systems = <Map<String, dynamic>>[
    {'id': 'sys', 'name': 'Test System'},
  ];
  var talkgroups = [talkgroup(1, 'Dispatch'), talkgroup(2, 'Fire')];
  // Talkgroups for particular systems; others get [talkgroups].
  final talkgroupsBySystem = <String, List<Map<String, dynamic>>>{};
  final talkgroupSystems = <String?>[];
  List<Map<String, dynamic>> latestCalls = [];
  // Handed out one per before_ts request, then empty: the end of history.
  List<List<Map<String, dynamic>>> olderPages = [];
  bool failCalls = false;
  bool failOlderCalls = false;
  final streams = <StreamController<List<int>>>[];

  // A relay at relay.test.
  String relayKey = 'good-key';
  String relayPush = 'fcm';
  bool relayDown = false;
  final relayRequests = <http.Request>[];

  List<Map<String, dynamic>> get relayPuts => [
        for (final request in relayRequests)
          if (request.method == 'PUT') jsonDecode(request.body)
      ];

  void send(Map<String, dynamic> event) {
    streams.last.add(utf8.encode('data:${jsonEncode(event)}\n\n'));
  }

  late final client = MockClient.streaming((request, _) async {
    final path = request.url.path;
    if (request.url.host == 'relay.test') {
      if (relayDown) throw http.ClientException('Connection refused');
      relayRequests.add(request as http.Request);
      final authorized =
          request.headers['Authorization'] == 'Bearer $relayKey';
      final body = !authorized
          ? {'error': 'Missing or unknown access key.'}
          : path == '/v1/status'
              ? {
                  'ok': true,
                  'apiVersion': 1,
                  'keyName': 'aidan',
                  'push': relayPush,
                }
              : {'ok': true};
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(body))), authorized ? 200 : 401);
    }
    requests[path] = (requests[path] ?? 0) + 1;
    if (path.endsWith('/stream')) {
      final controller = StreamController<List<int>>();
      streams.add(controller);
      return http.StreamedResponse(controller.stream, 200);
    }

    Object? body;
    var status = 200;
    if (path.endsWith('/systems')) {
      body = systems;
    } else if (path.endsWith('/talkgroups')) {
      final system = request.url.queryParameters['system'];
      talkgroupSystems.add(system);
      body = talkgroupsBySystem[system] ?? talkgroups;
    } else if (path.endsWith('/calls')) {
      calls.add(request as http.Request);
      final isOlderPage = request.url.queryParameters.containsKey('before_ts');
      if (failCalls || (failOlderCalls && isOlderPage)) status = 500;
      if (isOlderPage) {
        body = olderPages.isEmpty ? [] : olderPages.removeAt(0);
      } else {
        body = latestCalls;
      }
    }
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))), status);
  });
}

class FakeBackupFiles implements BackupFiles {
  final saved = <String, String>{};
  String? toOpen;

  @override
  Future<bool> save(String fileName, String contents) async {
    saved[fileName] = contents;
    return true;
  }

  @override
  Future<String?> open() async => toOpen;
}

class FakePush implements PushService {
  @override
  bool available = true;
  String? token = 'push-token';
  int permissionRequests = 0;
  final messages = StreamController<Map<String, String>>.broadcast();
  final refreshes = StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async => token;
  @override
  Stream<String> get onTokenRefresh => refreshes.stream;
  @override
  Stream<Map<String, String>> get onMessage => messages.stream;
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }
}

AlertRule alertRule({
  String name = 'Fires',
  AlertMode mode = AlertMode.keywords,
  List<String> keywords = const ['fire'],
}) =>
    AlertRule(
      name: name,
      systemId: 'sys',
      systemName: 'Test System',
      talkgroups: [
        {'id': 1, 'name': 'Dispatch'}
      ],
      mode: mode,
      keywords: keywords,
    );

Map<String, dynamic> favoriteOf(int id) => {
      'systemId': 'sys',
      'talkgroups': [talkgroup(id, 'TG$id')]
    };

List<dynamic> favoriteIds(List<Map<String, dynamic>> favorites) =>
    favorites.map((f) => f['talkgroups'][0]['id']).toList();

/// The Settings page is long, so its tests use a tall screen to keep
/// everything built and tappable without scrolling.
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('backup files', () {
    test('favorites keep their order through a round trip', () {
      final favorites = [favoriteOf(3), favoriteOf(1), favoriteOf(2)];
      final parsed = parseFavoritesBackup(exportFavorites(favorites));
      expect(favoriteIds(parsed), [3, 1, 2]);
      expect(parsed.first['talkgroups'][0]['name'], 'TG3');
    });

    test('settings keep hidden systems through a round trip', () {
      final parsed = parseSettingsBackup(exportSettings(hiddenSystems: [
        {'id': 'very-bad', 'name': 'RIT'},
        {'id': 'other', 'name': ''},
      ]));
      expect(parsed.hiddenSystems.map((s) => s['id']), ['very-bad', 'other']);
      expect(parsed.hiddenSystems.first['name'], 'RIT');
    });

    test('bad files are refused with a reason', () {
      Matcher refusedWith(String text) => throwsA(isA<BackupException>()
          .having((e) => e.message, 'message', contains(text)));

      expect(() => parseFavoritesBackup('not json'),
          refusedWith("isn't a Clearcut Mobile backup"));
      expect(() => parseFavoritesBackup('{"favorites": []}'),
          refusedWith("isn't a Clearcut Mobile backup"));
      expect(() => parseFavoritesBackup(exportSettings(hiddenSystems: [])),
          refusedWith('Import Settings'));
      expect(() => parseSettingsBackup(exportFavorites([])),
          refusedWith('Import Favorites'));

      final newer = jsonDecode(exportFavorites([])) as Map<String, dynamic>;
      newer['version'] = backupVersion + 1;
      expect(() => parseFavoritesBackup(jsonEncode(newer)),
          refusedWith('newer version'));

      final damaged = jsonDecode(exportFavorites([favoriteOf(1)]));
      damaged['favorites'][0]['talkgroups'] = [];
      expect(() => parseFavoritesBackup(jsonEncode(damaged)),
          refusedWith('damaged'));

      expect(
          () => parseSettingsBackup(exportSettings(hiddenSystems: [
                {'id': 'a/b?c', 'name': ''}
              ])),
          refusedWith('damaged'));
    });
  });

  group('hidden systems', () {
    test('are listed after fetched systems, once, and survive a restart',
        () async {
      await http.runWithClient(() async {
        final state = MyAppState();
        await pumpEventQueue();
        state.addHiddenSystem('very-bad');
        state.addHiddenSystem('sys'); // Later added to the public list.
        state.updateHiddenSystem('very-bad', 'very-bad', 'RIT');
        expect(state.allSystems.map((s) => s['id']), ['sys', 'very-bad']);
        expect(state.allSystems.last['name'], 'RIT');
        expect(state.allSystems.last['hidden'], isTrue);
        await pumpEventQueue();

        final restarted = MyAppState();
        await pumpEventQueue();
        expect(restarted.hiddenSystems.map((s) => s['id']), ['very-bad', 'sys']);

        restarted.removeHiddenSystem('very-bad');
        expect(restarted.allSystems.map((s) => s['id']), ['sys']);
      }, () => FakeApi().client);
    });
  });

  test('imported favorites are added in order, or replace the current ones',
      () async {
    await http.runWithClient(() async {
      final state = MyAppState();
      await pumpEventQueue();
      state.addFavorite('sys', [talkgroup(1, 'TG1')]);

      final added = state.importFavorites(
          [favoriteOf(3), favoriteOf(1), favoriteOf(2)],
          replace: false);
      expect(added, 2);
      expect(favoriteIds(state.favorites), [1, 3, 2]);

      state.importFavorites([favoriteOf(2), favoriteOf(4)], replace: true);
      expect(favoriteIds(state.favorites), [2, 4]);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(favoriteIds(List<Map<String, dynamic>>.from(
              jsonDecode(prefs.getString('favorites')!))),
          [2, 4]);
    }, () => FakeApi().client);
  });

  group('call helpers', () {
    test('flattens transcript objects, null, and missing text', () {
      expect(
          normalizeCall(call('1', 1, transcript: {'text': 'hi'}))['transcript'],
          'hi');
      expect(normalizeCall(call('1', 1))['transcript'], '');
      expect(normalizeCall(call('1', 1, transcript: {}))['transcript'], '');
    });

    test('merging dedupes by id and sorts newest first', () {
      final merged = mergeCalls(
        [normalizeCall(call('a', 10))],
        [call('b', 20), call('a', 10)],
      );
      expect(merged.map((c) => c['id']), ['b', 'a']);
    });

    test('merging keeps a transcript the incoming copy lacks', () {
      final merged = mergeCalls(
        [normalizeCall(call('a', 10, transcript: {'text': 'kept'}))],
        [call('a', 10)],
      );
      expect(merged.single['transcript'], 'kept');
    });

    test('merging drops calls named in replacesCallIds', () {
      final merged = mergeCalls(
        [normalizeCall(call('old', 10))],
        [
          {
            ...call('new', 10),
            'replacesCallIds': ['old']
          }
        ],
      );
      expect(merged.map((c) => c['id']), ['new']);
    });

    test('audio URL drops the audio/ prefix', () {
      expect(audioUrlFor('audio/sys/1/a.m4a'),
          'https://audio.clearcutradio.app/sys/1/a.m4a');
    });

    test('timestamps are zero-padded', () {
      final time = DateTime(2026, 11, 2, 9, 5, 3);
      expect(formatTimestamp(time.millisecondsSinceEpoch ~/ 1000),
          '11/2/2026 09:05:03');
    });

    test('duration handles zero-length and missing times', () {
      expect(formatDuration(10, 15), '5 Sec');
      expect(formatDuration(10, 10), '<1 Sec');
      expect(formatDuration(10, null), '');
    });
  });

  test('moving favorites uses ReorderableListView indexes and is saved',
      () async {
    await http.runWithClient(() async {
      final state = MyAppState();
      await pumpEventQueue();
      for (final id in [1, 2, 3]) {
        state.addFavorite('sys', [talkgroup(id, 'TG$id')]);
      }
      List<dynamic> order() =>
          state.favorites.map((f) => f['talkgroups'][0]['id']).toList();

      state.moveFavorite(0, 3); // First item to the very end.
      expect(order(), [2, 3, 1]);
      state.moveFavorite(2, 0); // Last item back to the top.
      expect(order(), [1, 2, 3]);

      state.moveFavorite(0, 2);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('favorites')!) as List;
      expect(saved.map((f) => f['talkgroups'][0]['id']), [2, 1, 3]);
    }, () => FakeApi().client);
  });

  group('SSE parsing', () {
    Future<List<Map<String, dynamic>>> parse(List<String> lines) =>
        parseSseEvents(Stream.fromIterable(lines)).toList();

    test('decodes events', () async {
      expect(await parse(['data:{"a":1}', '', 'data: {"b":2}', '']), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('skips keepalives, comments, and malformed events', () async {
      expect(
          await parse([
            ':keepalive',
            '',
            '',
            'data:not json',
            '',
            'data:[1]',
            '',
            'data:{"ok":true}',
            '',
          ]),
          [
            {'ok': true}
          ]);
    });
  });

  group('SSE service', () {
    test('reconnects and reports it after the server closes the stream',
        () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final events = <Map<String, dynamic>>[];
        var reconnects = 0;
        final service = SSEService(
          systemName: 'sys',
          talkgroupIds: [1],
          onEvent: events.add,
          onReconnected: () => reconnects++,
        );

        service.start();
        await pumpEventQueue();
        expect(api.streams, hasLength(1));
        expect(reconnects, 0);

        api.send({'a': 1});
        await pumpEventQueue();
        expect(events, [
          {'a': 1}
        ]);

        await api.streams.first.close();
        await Future.delayed(Duration(milliseconds: 1200));
        expect(api.streams, hasLength(2));
        expect(reconnects, 1);

        service.stop();
      }, () => api.client);
    });

    test('replaces a stream that goes silent', () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final service = SSEService(
          systemName: 'sys',
          talkgroupIds: [1],
          onEvent: (_) {},
          idleTimeout: Duration(milliseconds: 100),
        );
        service.start();
        await pumpEventQueue();
        expect(api.streams, hasLength(1));

        // The silence times out, then the first retry waits a second.
        await Future.delayed(Duration(milliseconds: 1400));
        expect(api.streams.length, greaterThanOrEqualTo(2));

        service.stop();
      }, () => api.client);
    });

    test('stops for good when stopped', () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final service = SSEService(
          systemName: 'sys',
          talkgroupIds: [1],
          onEvent: (_) {},
        );
        service.start();
        await pumpEventQueue();
        service.stop();
        await api.streams.single.close();
        await Future.delayed(Duration(milliseconds: 1200));
        expect(api.streams, hasLength(1));
      }, () => api.client);
    });
  });

  group('favorites', () {
    Future<MyAppState> loadedState() async {
      final state = MyAppState();
      await pumpEventQueue();
      return state;
    }

    test('freshly fetched copies of a talkgroup are not added twice', () async {
      await http.runWithClient(() async {
        final state = await loadedState();
        state.addFavorite('sys', [talkgroup(1, 'A')]);
        state.addFavorite('sys', [talkgroup(1, 'A')]);
        expect(state.favorites, hasLength(1));
        expect(state.isFavorite('sys', [talkgroup(1, 'A')]), isTrue);
        expect(state.isFavorite('other', [talkgroup(1, 'A')]), isFalse);
        expect(state.isFavorite('sys', [talkgroup(2, 'B')]), isFalse);
      }, () => FakeApi().client);
    });

    test('talkgroup order does not matter', () async {
      await http.runWithClient(() async {
        final state = await loadedState();
        state.addFavorite('sys', [talkgroup(1, 'A'), talkgroup(2, 'B')]);
        expect(state.isFavorite('sys', [talkgroup(2, 'B'), talkgroup(1, 'A')]),
            isTrue);
      }, () => FakeApi().client);
    });

    test('survive a restart, and stored duplicates are cleaned up', () async {
      final entry = {
        'systemId': 'sys',
        'talkgroups': [talkgroup(1, 'A')]
      };
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([entry, entry, entry]),
      });
      await http.runWithClient(() async {
        final state = await loadedState();
        expect(state.favorites, hasLength(1));

        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('favorites')!), hasLength(1));

        state.removeFavorite('sys', [talkgroup(1, 'A')]);
        expect(state.favorites, isEmpty);
      }, () => FakeApi().client);
    });
  });

  test('feedback link has a readable subject', () {
    expect(feedbackEmailUri.toString(),
        'mailto:$feedbackEmail?subject=Clearcut%20Mobile%20Feedback%20Request');
  });

  group('notifications', () {
    test('relay addresses default to HTTPS and keep a given port and path',
        () {
      expect(relayBaseUri('relay.example.com', null).toString(),
          'https://relay.example.com');
      expect(relayBaseUri(' relay.example.com ', 8443).toString(),
          'https://relay.example.com:8443');
      expect(relayBaseUri('http://192.168.1.5:8080/', null).toString(),
          'http://192.168.1.5:8080');
      expect(relayBaseUri('https://example.com/relay/', null).toString(),
          'https://example.com/relay');
      expect(relayBaseUri('', null), isNull);
      expect(relayBaseUri('ftp://example.com', null), isNull);
    });

    test('keywords are split on commas without blanks or repeats', () {
      expect(parseKeywords('fire, , Fire,shots  fired ,*, mva*'),
          ['fire', 'shots  fired', 'mva*']);
    });

    test('notification IDs are stable and positive', () {
      expect(stableNotificationId('7525309475746480128'),
          stableNotificationId('7525309475746480128'));
      expect(stableNotificationId('a'), isNot(stableNotificationId('b')));
      expect(stableNotificationId('x' * 50), greaterThanOrEqualTo(0));
    });

    test('pushes read well as notifications', () {
      final call = describeAlert({'type': 'call', 'talkgroupName': 'Dispatch'});
      expect((call.title, call.body), ('Dispatch', 'New call'));

      final match = describeAlert({
        'type': 'transcript',
        'talkgroupName': 'Dispatch',
        'text': 'Structure fire',
        'keywords': 'fire',
        'rules': 'Fires',
      });
      expect(match.body, 'Structure fire');
      expect(match.summary, 'Matched: fire');
      expect(describeAlert({'type': 'transcript', 'rules': 'All'}).summary,
          'All');
    });

    test('a tapped notification leads to its talkgroup and call', () {
      final target = AlertTarget.fromPayload(jsonEncode({
        'systemId': 'sys',
        'talkgroupId': '7',
        'talkgroupName': 'Fire',
        'callId': 'c1',
      }))!;
      expect((target.systemId, target.talkgroupId, target.callId),
          ('sys', 7, 'c1'));
      expect(AlertTarget.fromPayload('nope'), isNull);
      expect(AlertTarget.fromPayload(jsonEncode({'systemId': 'sys'})), isNull);
    });

    test('a wrong key or address is reported and nothing is saved', () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final controller = NotificationController(FakePush());
        await controller.load();
        expect(await controller.connect('relay.test', null, 'bad-key'),
            contains("didn't accept this access key"));
        expect(await controller.connect('', null, 'good-key'),
            contains('address'));
        api.relayDown = true;
        expect(await controller.connect('relay.test', 8443, 'good-key'),
            contains("Couldn't reach a relay at relay.test:8443"));
        expect(controller.subscribed, isFalse);
        expect(api.relayPuts, isEmpty);
      }, () => api.client);
    });

    test('connecting registers the phone, and changes keep the relay in sync',
        () async {
      final api = FakeApi();
      final push = FakePush();
      await http.runWithClient(() async {
        final controller = NotificationController(push);
        await controller.load();
        expect(await controller.connect('relay.test', null, 'good-key'), isNull);
        expect(controller.status?.keyName, 'aidan');
        expect(push.permissionRequests, 1);
        expect(api.relayPuts.single['token'], 'push-token');
        expect(api.relayRequests.last.url.path,
            '/v1/devices/${controller.deviceId}');

        final rule = alertRule();
        await controller.saveRule(rule);
        final sent = api.relayPuts.last['rules'].single;
        // The fields the relay reads.
        expect(sent, containsPair('id', rule.id));
        expect(sent, containsPair('mode', 'keywords'));
        expect(sent, containsPair('systemId', 'sys'));
        expect(sent, containsPair('enabled', true));
        expect(sent['keywords'], ['fire']);
        expect(sent['talkgroups'], [
          {'id': 1, 'name': 'Dispatch'}
        ]);

        await controller.pause(Duration(hours: 1));
        expect(controller.isPaused, isTrue);
        expect(api.relayPuts.last['paused'], isTrue);
        expect(api.relayPuts.last['pausedUntil'], isA<int>());
        await controller.resume();
        expect(api.relayPuts.last['paused'], isFalse);

        await controller.saveRule(rule.copyWith(enabled: false));
        expect(api.relayPuts.last['rules'].single['enabled'], isFalse);
        await controller.deleteRule(rule.id);
        expect(api.relayPuts.last['rules'], isEmpty);

        // A new push token is sent along.
        push.token = 'new-token';
        push.refreshes.add('new-token');
        await pumpEventQueue();
        expect(api.relayPuts.last['token'], 'new-token');
      }, () => api.client);
    });

    test('a failed update is shown and can be retried', () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final controller = NotificationController(FakePush());
        await controller.load();
        await controller.connect('relay.test', null, 'good-key');
        api.relayDown = true;
        await controller.saveRule(alertRule());
        expect(controller.syncError, contains("Couldn't reach"));
        api.relayDown = false;
        expect(await controller.sync(), isNull);
        expect(controller.syncError, isNull);
        expect(api.relayPuts.last['rules'], hasLength(1));
      }, () => api.client);
    });

    test('unsubscribing leaves the relay and stops alerts, even offline',
        () async {
      final api = FakeApi();
      final shown = <Map<String, String>>[];
      await http.runWithClient(() async {
        final push = FakePush();
        final controller =
            NotificationController(push, showAlert: shown.add);
        await controller.load();
        await controller.connect('relay.test', null, 'good-key');
        push.messages.add({'type': 'test'});
        await pumpEventQueue();
        expect(shown, hasLength(1));

        api.relayDown = true;
        expect(await controller.unsubscribe(), contains("couldn't be told"));
        expect(controller.subscribed, isFalse);
        expect(await alertsAllowedFromStorage(), isFalse);
        push.messages.add({'type': 'test'});
        await pumpEventQueue();
        expect(shown, hasLength(1));

        api.relayDown = false;
        await controller.connect('relay.test', null, 'good-key');
        expect(await controller.unsubscribe(), isNull);
        expect(api.relayRequests.last.method, 'DELETE');
      }, () => api.client);
    });

    test('a new key registers as a new device and drops the old one',
        () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final controller = NotificationController(FakePush());
        await controller.load();
        await controller.connect('relay.test', null, 'good-key');
        final oldId = controller.deviceId;

        api.relayKey = 'second-key';
        // The old registration can only be removed with the old key, which
        // the relay still accepts here.
        api.relayKey = 'good-key';
        await controller.connect('relay.test', null, 'good-key');
        expect(controller.deviceId, oldId); // Same key, same device.

        api.relayKey = 'other-key';
        await controller.connect('relay.test', null, 'other-key');
        expect(controller.deviceId, isNot(oldId));
        expect(api.relayRequests.any((r) =>
                r.method == 'DELETE' && r.url.path.endsWith(oldId)), isTrue);
      }, () => api.client);
    });

    test('settings and pauses survive a restart, and pauses run out',
        () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final controller = NotificationController(FakePush());
        await controller.load();
        await controller.connect('relay.test', 8443, 'good-key');
        await controller.saveRule(alertRule());
        await controller.pause(null);
        expect(await alertsAllowedFromStorage(), isFalse);

        final restarted = NotificationController(FakePush());
        await restarted.load();
        expect(restarted.port, 8443);
        expect(restarted.key, 'good-key');
        expect(restarted.deviceId, controller.deviceId);
        expect(restarted.rules.single.name, 'Fires');
        expect(restarted.isPaused, isTrue);
        expect(restarted.pausedUntil, isNull);

        await restarted.resume();
        expect(await alertsAllowedFromStorage(), isTrue);
      }, () => api.client);
      expect(
          isPausedJson({
            'paused': true,
            'pausedUntil': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 5,
          }),
          isFalse);
    });

    test('settings backups carry the server and rules but never the key',
        () async {
      final api = FakeApi();
      await http.runWithClient(() async {
        final controller = NotificationController(FakePush());
        await controller.load();
        await controller.connect('relay.test', 8443, 'good-key');
        await controller.saveRule(alertRule());

        final file = exportSettings(
            hiddenSystems: [], notifications: controller.toBackupJson());
        expect(file, isNot(contains('good-key')));

        final fresh = NotificationController(FakePush());
        final backup = parseSettingsBackup(file).notifications;
        expect(await fresh.importBackup(backup, replace: false), 1);
        expect(fresh.address, 'relay.test');
        expect(fresh.port, 8443);
        expect(fresh.key, isEmpty);
        expect(fresh.rules.single.keywords, ['fire']);
        // The same rule isn't added twice.
        expect(await fresh.importBackup(backup, replace: false), 0);
      }, () => api.client);
    });
  });

  group('pages', () {
    Future<void> pumpApp(WidgetTester tester, Widget home) async {
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => MyAppState(),
        child: MaterialApp(home: home),
      ));
      await tester.pumpAndSettle();
    }

    // Resuming the app drops the stream and catches up, as any reconnect does.
    Future<void> reconnectByResuming(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    // Replaces the page, so it's disposed and the stream closes.
    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(SizedBox());
      await tester.pump(Duration(seconds: 1));
    }

    testWidgets('searching talkgroups keeps the field and does not re-fetch',
        (tester) async {
      final api = FakeApi();
      await http.runWithClient(() async {
        await pumpApp(tester, MySystemsPage());
        await tester.tap(find.text('Test System'));
        await tester.pumpAndSettle();
        expect(api.requests['/api/v1/talkgroups'], 1);

        final field = find.byType(TextField);
        await tester.enterText(field, 'fir');
        await tester.pump();

        // No spinner frame, and the same field still holds what was typed.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.widgetWithText(TextField, 'fir'), findsOneWidget);
        expect(find.text('Fire'), findsOneWidget);
        expect(find.text('Dispatch'), findsNothing);

        await tester.pumpAndSettle();
        expect(api.requests['/api/v1/talkgroups'], 1);
      }, () => api.client);
    });

    testWidgets('a selection hidden by search is still listened to',
        (tester) async {
      final api = FakeApi();
      await http.runWithClient(() async {
        await pumpApp(tester, MySystemsPage());
        await tester.tap(find.text('Test System'));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(Checkbox).first); // Dispatch
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'fire');
        await tester.pump();
        await tester.tap(find.text('Listen to Selected (1)'));
        await tester.pumpAndSettle();

        expect(
            api.calls.single.url.queryParameters['talkgroup'], '1');
        await leave(tester);
      }, () => api.client);
    });

    testWidgets('every system is reachable on a small screen with large text',
        (tester) async {
      final api = FakeApi()
        ..systems = [
          for (var i = 0; i < 7; i++) {'id': 's$i', 'name': 'System $i'}
        ];
      tester.view.physicalSize = Size(320, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await http.runWithClient(() async {
        await pumpApp(tester, MySystemsPage());
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.favorite_border), findsOneWidget);
        await tester.scrollUntilVisible(find.text('System 6'), 100,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('System 6'), findsOneWidget);
      }, () => api.client);
    });

    testWidgets('a failed systems load offers a working retry', (tester) async {
      var attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        return attempts == 1
            ? http.Response('nope', 500)
            : http.Response(
                jsonEncode([
                  {'id': 'sys', 'name': 'Test System'}
                ]),
                200);
      });
      await http.runWithClient(() async {
        await pumpApp(tester, MySystemsPage());
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Test System'), findsOneWidget);
      }, () => client);
    });

    testWidgets('drawer navigation leaves the favorites view', (tester) async {
      final api = FakeApi();
      await http.runWithClient(() async {
        await pumpApp(tester, MySystemsPage());
        await tester.tap(find.byIcon(Icons.favorite_border));
        await tester.pump();
        expect(find.text('No favorites yet.'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.menu));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Systems').last);
        await tester.pumpAndSettle();
        expect(find.text('Test System'), findsOneWidget);
      }, () => api.client);
    });

    testWidgets('favorites can be dragged into a new order', (tester) async {
      final api = FakeApi();
      SharedPreferences.setMockInitialValues({
        'favorites': jsonEncode([
          for (final id in [1, 2, 3])
            {
              'systemId': 'sys',
              'talkgroups': [talkgroup(id, 'TG$id')]
            }
        ]),
      });
      await http.runWithClient(() async {
        await pumpApp(tester, Scaffold(body: FavoritesPage()));
        final first = tester.getCenter(find.byIcon(Icons.drag_handle).first);
        final gesture = await tester.startGesture(first);
        await tester.pump(Duration(milliseconds: 100));
        await gesture.moveBy(Offset(0, 200));
        await tester.pump(Duration(milliseconds: 100));
        await gesture.up();
        await tester.pumpAndSettle();

        final state = tester
            .element(find.byType(FavoritesPage))
            .read<MyAppState>();
        expect(state.favorites.first['talkgroups'][0]['id'], isNot(1));
        expect(state.favorites, hasLength(3));
      }, () => api.client);
    });

    group('settings', () {
      Future<void> openSettings(WidgetTester tester) async {
        await tester.tap(find.byIcon(Icons.menu));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
      }

      // Lets a snack bar time out, so no timer is left when the test ends.
      Future<void> finishMessages(WidgetTester tester) async {
        await tester.pump(Duration(seconds: 10));
        await tester.pumpAndSettle();
      }

      MyAppState stateOf(WidgetTester tester) =>
          tester.element(find.byType(Scaffold).first).read<MyAppState>();

      testWidgets('a hidden system added in settings opens its talkgroups',
          (tester) async {
        useTallScreen(tester);
        final api = FakeApi()
          ..talkgroupsBySystem['very-bad'] = [talkgroup(100, 'RIT UHF Ops')];
        await http.runWithClient(() async {
          await pumpApp(tester, MySystemsPage());
          await openSettings(tester);
          await tester.enterText(find.byType(TextField), ' very-bad ');
          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          expect(find.text('Added very-bad to the Systems page.'),
              findsOneWidget);
          expect(find.text('ID: very-bad'), findsOneWidget);

          await tester.tap(find.byIcon(Icons.menu));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Systems').last);
          await tester.pumpAndSettle();
          expect(find.text('Test System'), findsOneWidget);
          await tester.tap(find.text('very-bad'));
          await tester.pumpAndSettle();

          expect(api.talkgroupSystems.last, 'very-bad');
          expect(find.text('RIT UHF Ops'), findsOneWidget);
          expect(find.text('very-bad'), findsOneWidget); // Page title.
          await finishMessages(tester);
        }, () => api.client);
      });

      testWidgets('hidden systems still show when the system list fails',
          (tester) async {
        useTallScreen(tester);
        SharedPreferences.setMockInitialValues({
          'hiddenSystems': jsonEncode([
            {'id': 'very-bad', 'name': 'RIT'}
          ]),
        });
        final client = MockClient((_) async => http.Response('nope', 500));
        await http.runWithClient(() async {
          await pumpApp(tester, MySystemsPage());
          expect(find.text("Couldn't load systems."), findsOneWidget);
          expect(find.text('RIT'), findsOneWidget);
        }, () => client);
      });

      testWidgets('an ID with no talkgroups asks before it is added',
          (tester) async {
        useTallScreen(tester);
        final api = FakeApi()..talkgroupsBySystem['typo'] = [];
        await http.runWithClient(() async {
          await pumpApp(tester, MySystemsPage());
          await openSettings(tester);
          await tester.enterText(find.byType(TextField), 'typo');
          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          expect(find.textContaining('no talkgroups for "typo"'),
              findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(stateOf(tester).hiddenSystems, isEmpty);

          await tester.tap(find.text('Add'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Add Anyway'));
          await tester.pumpAndSettle();
          expect(stateOf(tester).hiddenSystems.single['id'], 'typo');
          await finishMessages(tester);
        }, () => api.client);
      });

      testWidgets('bad and duplicate IDs are refused without a lookup',
          (tester) async {
        useTallScreen(tester);
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester, MySystemsPage());
          await openSettings(tester);
          for (final (id, reason) in [
            ('bad id/x', 'only use letters'),
            ('sys', 'already on the Systems page'),
          ]) {
            await tester.enterText(find.byType(TextField), id);
            await tester.tap(find.text('Add'));
            await tester.pumpAndSettle();
            expect(find.textContaining(reason), findsOneWidget);
          }
          expect(api.talkgroupSystems, isEmpty);
          expect(stateOf(tester).hiddenSystems, isEmpty);
          await finishMessages(tester);
        }, () => api.client);
      });

      testWidgets('a hidden system can be renamed and removed',
          (tester) async {
        useTallScreen(tester);
        SharedPreferences.setMockInitialValues({
          'hiddenSystems': jsonEncode([
            {'id': 'very-bad', 'name': ''}
          ]),
        });
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester, MySystemsPage());
          await openSettings(tester);
          await tester.tap(find.byTooltip('Edit'));
          await tester.pumpAndSettle();
          await tester.enterText(
              find.widgetWithText(TextField, 'Display name'), 'RIT');
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(stateOf(tester).allSystems.last['name'], 'RIT');
          expect(api.talkgroupSystems, isEmpty); // Same ID, no lookup.

          await tester.tap(find.byTooltip('Remove'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Remove').last);
          await tester.pumpAndSettle();
          expect(stateOf(tester).hiddenSystems, isEmpty);
        }, () => api.client);
      });

      testWidgets('favorites export and import keep their order',
          (tester) async {
        useTallScreen(tester);
        SharedPreferences.setMockInitialValues({
          'favorites':
              jsonEncode([favoriteOf(1), favoriteOf(2), favoriteOf(3)]),
        });
        final files = FakeBackupFiles();
        await http.runWithClient(() async {
          await pumpApp(tester, Scaffold(body: SettingsPage(files: files)));
          await tester.tap(find.text('Export Favorites'));
          await tester.pumpAndSettle();
          expect(favoriteIds(parseFavoritesBackup(files.saved.values.single)),
              [1, 2, 3]);

          files.toOpen = exportFavorites([favoriteOf(3), favoriteOf(1)]);
          await tester.tap(find.text('Import Favorites'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Replace'));
          await tester.pumpAndSettle();
          expect(favoriteIds(stateOf(tester).favorites), [3, 1]);

          files.toOpen = exportFavorites([favoriteOf(2), favoriteOf(3)]);
          await tester.tap(find.text('Import Favorites'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Add').last);
          await tester.pumpAndSettle();
          expect(favoriteIds(stateOf(tester).favorites), [3, 1, 2]);
          expect(find.text('Imported 1 favorite. You already had 1 other.'),
              findsOneWidget);
          await finishMessages(tester);
        }, () => FakeApi().client);
      });

      testWidgets('settings export and import carry hidden systems',
          (tester) async {
        useTallScreen(tester);
        final files = FakeBackupFiles()
          ..toOpen = exportSettings(hiddenSystems: [
            {'id': 'very-bad', 'name': 'RIT'}
          ]);
        await http.runWithClient(() async {
          await pumpApp(tester, Scaffold(body: SettingsPage(files: files)));
          await tester.tap(find.text('Import Settings'));
          await tester.pumpAndSettle();
          expect(find.text('RIT'), findsOneWidget);

          await tester.tap(find.text('Export Settings'));
          await tester.pumpAndSettle();
          expect(
              parseSettingsBackup(files.saved.values.single)
                  .hiddenSystems
                  .single['id'],
              'very-bad');
          await finishMessages(tester);
        }, () => FakeApi().client);
      });

      testWidgets('importing the wrong kind of file says why', (tester) async {
        useTallScreen(tester);
        final files = FakeBackupFiles()
          ..toOpen = exportSettings(hiddenSystems: []);
        await http.runWithClient(() async {
          await pumpApp(tester, Scaffold(body: SettingsPage(files: files)));
          await tester.tap(find.text('Import Favorites'));
          await tester.pumpAndSettle();
          expect(find.textContaining('This is a settings backup'),
              findsOneWidget);
          expect(stateOf(tester).favorites, isEmpty);
          await finishMessages(tester);
        }, () => FakeApi().client);
      });
    });

    group('notification settings', () {
      Future<FakePush> pumpSettings(WidgetTester tester) async {
        final push = FakePush();
        await tester.pumpWidget(ChangeNotifierProvider(
          create: (_) => MyAppState(push: push),
          child: MaterialApp(home: Scaffold(body: SettingsPage())),
        ));
        await tester.pumpAndSettle();
        return push;
      }

      Future<void> finishMessages(WidgetTester tester) async {
        await tester.pump(Duration(seconds: 10));
        await tester.pumpAndSettle();
      }

      testWidgets('a build without push support says so', (tester) async {
        useTallScreen(tester);
        await http.runWithClient(() async {
          await pumpApp(tester, Scaffold(body: SettingsPage()));
          expect(find.text('Not available in this copy of the app'),
              findsOneWidget);
        }, () => FakeApi().client);
      });

      testWidgets('connecting and adding a keyword rule', (tester) async {
        useTallScreen(tester);
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpSettings(tester);
          await tester.enterText(
              find.widgetWithText(TextField, 'Server address'), 'relay.test');
          await tester.enterText(
              find.widgetWithText(TextField, 'Access key'), 'bad-key');
          await tester.tap(find.text('Connect'));
          await tester.pumpAndSettle();
          expect(find.textContaining("didn't accept this access key"),
              findsOneWidget);

          await tester.enterText(
              find.widgetWithText(TextField, 'Access key'), 'good-key');
          await tester.tap(find.text('Connect'));
          await tester.pumpAndSettle();
          expect(find.text('Connected to relay.test'), findsOneWidget);
          expect(find.text('Key: aidan'), findsOneWidget);

          await tester.scrollUntilVisible(find.text('Add Rule'), 200,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('Add Rule'));
          await tester.pumpAndSettle();

          await tester.enterText(
              find.widgetWithText(TextField, 'Keywords'), 'fire, mva*');
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Test System').last);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('Fire'), 200,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('Fire'));
          await tester.pump();
          expect(find.text('Talkgroups (1 chosen)'), findsOneWidget);
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          final rule = api.relayPuts.last['rules'].single;
          expect(rule['name'], 'Fire');
          expect(rule['keywords'], ['fire', 'mva*']);
          expect(rule['talkgroups'], [
            {'id': 2, 'name': 'Fire'}
          ]);
          await tester.scrollUntilVisible(
              find.text('Keywords: fire, mva* · Fire on Test System'), 200,
              scrollable: find.byType(Scrollable).first);
          await finishMessages(tester);
        }, () => api.client);
      });

      testWidgets('a rule needs talkgroups and keywords', (tester) async {
        useTallScreen(tester);
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpSettings(tester);
          final controller = tester
              .element(find.byType(SettingsPage))
              .read<MyAppState>()
              .notifications;
          await controller.connect('relay.test', null, 'good-key');
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('Add Rule'), 200,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('Add Rule'));
          await tester.pumpAndSettle();

          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Choose a system.'), findsOneWidget);
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Test System').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Choose at least one talkgroup.'), findsOneWidget);
          await tester.scrollUntilVisible(find.text('Dispatch'), 200,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('Dispatch'));
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.text('Enter at least one keyword.'), findsOneWidget);
          expect(controller.rules, isEmpty);
          await finishMessages(tester);
        }, () => api.client);
      });

      testWidgets('pausing, resuming, and a relay that can\'t push',
          (tester) async {
        useTallScreen(tester);
        final api = FakeApi()..relayPush = 'log';
        await http.runWithClient(() async {
          await pumpSettings(tester);
          final controller = tester
              .element(find.byType(SettingsPage))
              .read<MyAppState>()
              .notifications;
          await controller.connect('relay.test', null, 'good-key');
          await tester.pumpAndSettle();
          expect(find.text("The relay can't send notifications yet"),
              findsOneWidget);

          await tester.tap(find.text('Pause Notifications'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Until I resume'));
          await tester.pumpAndSettle();
          expect(find.text('Paused until you resume'), findsOneWidget);
          expect(api.relayPuts.last['paused'], isTrue);

          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
          expect(find.text('Pause Notifications'), findsOneWidget);
          expect(api.relayPuts.last['paused'], isFalse);
        }, () => api.client);
      });
    });

    group('listener', () {
      final selected = [talkgroup(1, 'Dispatch')];

      testWidgets('live events add calls and fill in transcripts',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = [call('a', 10, transcript: {'text': 'first'})];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          expect(find.text('first'), findsOneWidget);

          api.send({'upload': call('b', 20)});
          await tester.pump();
          await tester.pump();
          expect(find.text('Transcribe Call'), findsOneWidget);

          api.send({
            'transcript': {'callId': 'b', 'text': 'second'}
          });
          await tester.pump();
          await tester.pump();
          expect(find.text('second'), findsOneWidget);
          expect(find.text('Transcribe Call'), findsNothing);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('refreshing does not open a second stream or duplicate calls',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = [call('a', 10, transcript: {'text': 'first'})];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          await tester.fling(
              find.byType(ListView), Offset(0, 400), 1000);
          await tester.pumpAndSettle();

          final latestFetches = api.calls.where(
              (c) => !c.url.queryParameters.containsKey('before_ts'));
          expect(latestFetches, hasLength(2));
          expect(api.streams, hasLength(1));
          expect(find.text('first'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('leaving the page closes the stream', (tester) async {
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          expect(api.streams, hasLength(1));
          await leave(tester);

          // An event arriving afterwards must not touch the disposed page.
          api.send({'upload': call('late', 1)});
          await tester.pump(Duration(seconds: 40));
          expect(tester.takeException(), isNull);
          expect(api.streams, hasLength(1));
        }, () => api.client);
      });

      List<Map<String, dynamic>> calls(int count, int start,
              {String text = 'chatter'}) =>
          [
            for (var i = 0; i < count; i++)
              call('c${start - i}', start - i, transcript: {'text': text})
          ];

      testWidgets('a short list pages back by itself to the end of history',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = [
            call('a', 20, transcript: {'text': 'new'})
          ]
          ..olderPages = [
            [
              call('b', 10, transcript: {'text': 'old'})
            ]
          ];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          expect(find.text('old'), findsOneWidget);
          expect(api.calls[1].url.queryParameters['before_ts'], '20');
          expect(find.text('No older calls.'), findsOneWidget);
          expect(find.text('Load More Calls'), findsNothing);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('scrolling near the end loads older calls, in order',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = calls(40, 1000)
          ..olderPages = [calls(40, 900), calls(40, 800)];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          // A long list stays put until it's scrolled.
          expect(api.calls, hasLength(1));

          await tester.drag(find.byType(ListView), Offset(0, -100000));
          await tester.pumpAndSettle();
          expect(api.calls.map((c) => c.url.queryParameters['before_ts']),
              contains('961'));
          expect(api.calls.length, greaterThan(1));

          final state = tester.state(find.byType(ListenerPage)) as dynamic;
          final times = (state.callData as List).map((c) => c['startTime']);
          expect(times.toList(), times.toList()..sort((a, b) => b - a));

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('a failed older page waits for a tap instead of looping',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = calls(1, 100)
          ..failOlderCalls = true;
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          final attempts = api.calls.length;
          expect(find.text('Load More Calls'), findsOneWidget);
          await tester.pump(Duration(seconds: 5));
          expect(api.calls, hasLength(attempts));

          api
            ..failOlderCalls = false
            ..olderPages = [
              [
                call('b', 50, transcript: {'text': 'recovered'})
              ]
            ];
          await tester.tap(find.text('Load More Calls'));
          await tester.pumpAndSettle();
          expect(find.text('recovered'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('search finds transcripts in pages not loaded yet',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = calls(40, 1000)
          ..olderPages = [
            calls(40, 900),
            [
              call('hit', 800, transcript: {'text': 'Structure Fire'})
            ],
          ];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          expect(api.calls, hasLength(1));

          await tester.enterText(find.byType(TextField), 'structure');
          await tester.pumpAndSettle();
          expect(find.text('Structure Fire'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('search stops after its page limit and can continue',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = calls(40, 10000)
          ..olderPages = [
            for (var i = 1; i <= 18; i++) calls(5, 9000 - i * 10)
          ];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          expect(api.calls, hasLength(1));

          await tester.enterText(find.byType(TextField), 'nothing matches');
          await tester.pumpAndSettle();
          expect(api.calls, hasLength(1 + 12));
          expect(find.text('Search Further Back'), findsOneWidget);

          await tester.tap(find.text('Search Further Back'));
          await tester.pumpAndSettle();
          // Six pages remain, then one empty page marks the end of history.
          expect(api.calls, hasLength(1 + 12 + 6 + 1));
          expect(find.text('No older calls.'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('a reconnect after a long gap leaves no hole in the list',
          (tester) async {
        final api = FakeApi()
          ..latestCalls = calls(40, 1000)
          ..olderPages = [];
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          api.latestCalls = calls(40, 9000); // Nothing overlaps with 961-1000.
          await reconnectByResuming(tester);
          expect(api.streams, hasLength(2));

          final state = tester.state(find.byType(ListenerPage)) as dynamic;
          final ids = (state.callData as List).map((c) => c['id']);
          expect(ids, contains('c9000'));
          expect(ids, isNot(contains('c1000')));
          expect(state.hasMoreCalls, isTrue);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('a reconnect after a short gap keeps what is loaded',
          (tester) async {
        final api = FakeApi()..latestCalls = calls(40, 1000);
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));

          api.latestCalls = calls(40, 1010); // Overlaps, and adds ten new calls.
          await reconnectByResuming(tester);

          final state = tester.state(find.byType(ListenerPage)) as dynamic;
          expect(state.callData, hasLength(50));

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('returning to the app reconnects at once and catches up',
          (tester) async {
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          final fetches = api.calls.length;

          api.latestCalls = [
            call('missed', 500, transcript: {'text': 'while asleep'})
          ];
          await reconnectByResuming(tester);

          expect(api.streams, hasLength(2));
          expect(api.calls.length, greaterThan(fetches));
          expect(find.text('while asleep'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('favorites are reachable from the stream page',
          (tester) async {
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          await tester.tap(find.byIcon(Icons.favorite_border));
          await tester.pump();
          expect(find.text('No favorites yet.'), findsOneWidget);

          await tester.tap(find.byIcon(Icons.favorite));
          await tester.pump();
          expect(find.text('Search Calls'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('opening a favorite from a stream closes that stream',
          (tester) async {
        final api = FakeApi();
        SharedPreferences.setMockInitialValues({
          'favorites': jsonEncode([
            {
              'systemId': 'sys',
              'talkgroups': [talkgroup(2, 'Fire')]
            }
          ]),
        });
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          await tester.tap(find.byIcon(Icons.favorite_border));
          await tester.pump();
          await tester.tap(find.text('Fire'));
          await tester.pumpAndSettle();

          expect(find.byType(ListenerPage), findsOneWidget);
          expect(api.streams, hasLength(2));
          expect(api.streams.first.hasListener, isFalse);
          expect(api.streams.last.hasListener, isTrue);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('the call a notification was about is highlighted',
          (tester) async {
        final api = FakeApi()..latestCalls = [call('a', 20), call('b', 10)];
        await http.runWithClient(() async {
          await pumpApp(
              tester,
              ListenerPage(
                selectedTalkgroups: selected,
                currentSystem: 'sys',
                highlightCallId: 'b',
              ));
          final card = tester.widget<Card>(
              find.byKey(ValueKey('highlighted-call')));
          expect(card.shape, isA<RoundedRectangleBorder>());
          expect(find.byKey(ValueKey('highlighted-call')), findsOneWidget);
          await leave(tester);
        }, () => api.client);
      });

      testWidgets('a failed load offers a working retry', (tester) async {
        final api = FakeApi()..failCalls = true;
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          expect(find.text("Couldn't load calls."), findsOneWidget);

          api
            ..failCalls = false
            ..latestCalls = [call('a', 10, transcript: {'text': 'back'})];
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('back'), findsOneWidget);

          await leave(tester);
        }, () => api.client);
      });

      testWidgets('the favorites button goes away once favorited',
          (tester) async {
        final api = FakeApi();
        await http.runWithClient(() async {
          await pumpApp(tester,
              ListenerPage(selectedTalkgroups: selected, currentSystem: 'sys'));
          await tester.tap(find.text('Add Talkgroup(s) to Favorites'));
          await tester.pump();
          expect(find.text('Add Talkgroup(s) to Favorites'), findsNothing);

          await leave(tester);
        }, () => api.client);
      });
    });
  });
}
