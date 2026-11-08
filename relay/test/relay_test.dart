import 'dart:convert';
import 'dart:io';

import 'package:clearcut_relay/relay.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class FakePush extends PushSender {
  final sent = <(String, Map<String, String>)>[];
  var result = PushResult.sent;

  @override
  String get kind => 'fake';

  @override
  Future<PushResult> send(String token, Map<String, String> data) async {
    sent.add((token, data));
    return result;
  }
}

class FakeStream implements EventStream {
  final String system;
  final List<int> talkgroups;
  bool running = false;
  FakeStream(this.system, this.talkgroups);

  @override
  void start() => running = true;

  @override
  void stop() => running = false;
}

Map<String, dynamic> ruleJson({
  String id = 'r1',
  String name = 'Rule',
  String system = 'sys',
  List<int> talkgroups = const [1],
  String mode = 'all',
  List<String> keywords = const [],
  bool enabled = true,
}) => {
  'id': id,
  'name': name,
  'enabled': enabled,
  'systemId': system,
  'talkgroups': [
    for (final tg in talkgroups) {'id': tg, 'name': 'TG$tg'},
  ],
  'mode': mode,
  'keywords': keywords,
};

Map<String, dynamic> upload(
  String id,
  int tg, {
  List<String> replaces = const [],
}) => {
  'upload': {
    'id': id,
    'systemId': 'sys',
    'talkgroup': tg,
    'startTime': 100,
    'endTime': 102,
    'replacesCallIds': replaces,
  },
};

Map<String, dynamic> transcript(String callId, int tg, String text) => {
  'transcript': {
    'callId': callId,
    'systemId': 'sys',
    'talkgroup': tg,
    'talkgroupName': 'Live Name',
    'text': text,
  },
};

void main() {
  late Directory dir;
  late RelayStore store;
  late FakePush push;
  late List<FakeStream> streams;
  late Relay relay;
  late DateTime now;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('relay_test');
    store = RelayStore(dir);
    push = FakePush();
    streams = [];
    now = DateTime.utc(2026, 11, 8, 12);
    relay = Relay(
      store,
      push,
      now: () => now,
      streamFactory: (system, tgs, onEvent) {
        final stream = FakeStream(system, tgs);
        streams.add(stream);
        return stream;
      },
    );
  });

  tearDown(() {
    relay.stop();
    dir.deleteSync(recursive: true);
  });

  Device addDevice(
    String id,
    List<Map<String, dynamic>> rules, {
    String keyId = 'k',
    bool paused = false,
    DateTime? pausedUntil,
  }) {
    final device = Device(
      id: id,
      keyId: keyId,
      token: 'token-$id',
      rules: [for (final rule in rules) Rule.fromJson(rule)],
      paused: paused,
      pausedUntil: pausedUntil,
      updated: now,
    );
    store.devices[id] = device;
    return device;
  }

  List<FakeStream> running() => streams.where((s) => s.running).toList();

  group('keywords', () {
    bool matches(String keyword, String text) =>
        keywordPattern(keyword).hasMatch(text);

    test('match whole words, ignoring case', () {
      expect(matches('fire', 'Structure FIRE reported'), isTrue);
      expect(matches('fire', 'fire.'), isTrue);
      expect(matches('fire', 'firearm'), isFalse);
      expect(matches('fire', 'campfire'), isFalse);
    });

    test('a trailing star matches any ending', () {
      expect(matches('fire*', 'firearm'), isTrue);
      expect(matches('fire*', 'campfire'), isFalse);
    });

    test('phrases match across any whitespace, and symbols are literal', () {
      expect(matches('shots  fired', 'shots\nfired'), isTrue);
      expect(matches('10-50', 'a 10-50 PI'), isTrue);
      expect(matches('10-50', '10x50'), isFalse);
      expect(matches('c.p.r', 'start cpr'), isFalse);
    });

    test('a rule reports which keywords it found', () {
      final rule = Rule.fromJson(
        ruleJson(mode: 'keywords', keywords: ['fire', 'MVA', ' ', '*']),
      );
      expect(rule.keywords, ['fire', 'MVA']);
      expect(rule.matchingKeywords('mva with fire'), ['fire', 'MVA']);
    });
  });

  group('firebase errors', () {
    String body(String status, String? errorCode, String message) => jsonEncode(
      {
        'error': {
          'code': 400,
          'message': message,
          'status': status,
          'details': [
            if (errorCode != null)
              {
                '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
                'errorCode': errorCode,
              },
          ],
        },
      },
    );

    test('only unregistered or malformed tokens drop a phone', () {
      expect(
        FcmError.parse(
          404,
          body('NOT_FOUND', 'UNREGISTERED', 'Requested entity was not found.'),
        ).tokenIsDead,
        isTrue,
      );
      expect(
        FcmError.parse(
          400,
          body(
            'INVALID_ARGUMENT',
            'INVALID_ARGUMENT',
            'The registration token is not a valid FCM registration token',
          ),
        ).tokenIsDead,
        isTrue,
      );

      final mismatch = FcmError.parse(
        403,
        body('PERMISSION_DENIED', 'SENDER_ID_MISMATCH', 'SenderId mismatch'),
      );
      expect(mismatch.tokenIsDead, isFalse);
      expect(mismatch.hint, contains('different Firebase project'));

      // A bare 404, such as a wrong project in the URL, isn't the phone's fault.
      expect(FcmError.parse(404, 'Not Found').tokenIsDead, isFalse);
      expect(
        FcmError.parse(
          400,
          body(
            'INVALID_ARGUMENT',
            'INVALID_ARGUMENT',
            'Invalid data payload key',
          ),
        ).tokenIsDead,
        isFalse,
      );
    });
  });

  group('rules from the app', () {
    void rejects(Map<String, dynamic> json, String reason) {
      expect(
        () => Rule.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(reason),
          ),
        ),
      );
    }

    test('are checked', () {
      rejects(ruleJson(system: 'a/b'), 'invalid system ID');
      rejects(ruleJson(talkgroups: []), 'talkgroups');
      rejects(ruleJson(mode: 'sometimes'), 'unknown mode');
      rejects(ruleJson(mode: 'keywords'), 'at least one keyword');
      rejects({...ruleJson(), 'enabled': 'yes'}, 'enabled');
    });

    test('survive being saved', () {
      final rule = Rule.fromJson(ruleJson(mode: 'keywords', keywords: ['a']));
      expect(
        Rule.fromJson(jsonDecode(jsonEncode(rule.toJson()))).toJson(),
        rule.toJson(),
      );
    });
  });

  group('store', () {
    test('keys authenticate until revoked, and only hashes are stored', () {
      final (key, secret) = store.createKey('alice');
      expect(secret, startsWith(keyPrefix));
      expect(keysFileText(store), isNot(contains(secret)));
      expect(store.authenticate(secret)?.name, 'alice');
      expect(store.authenticate('${secret}x'), isNull);
      expect(() => store.createKey('alice'), throwsStateError);

      // As the command-line tool would, from another process.
      expect(RelayStore(dir).revokeKey('alice'), isTrue);
      expect(store.authenticate(secret), isNull);
      expect(key.name, 'alice');
    });

    test('revoking a key drops its phones', () {
      final (key, _) = store.createKey('alice');
      addDevice('d1', [ruleJson()], keyId: key.id);
      addDevice('d2', [ruleJson()], keyId: 'gone');
      expect(store.removeOrphanedDevices(), isTrue);
      expect(store.devices.keys, ['d1']);
    });

    test('devices survive a restart', () {
      addDevice(
        'd1',
        [
          ruleJson(mode: 'keywords', keywords: ['fire']),
        ],
        paused: true,
        pausedUntil: now.add(Duration(hours: 1)),
      );
      store.saveDevicesNow();
      final reloaded = RelayStore(dir)..loadDevices();
      final device = reloaded.devices['d1']!;
      expect(device.rules.single.keywords, ['fire']);
      expect(device.pausedUntil, now.add(Duration(hours: 1)));
    });
  });

  group('relay', () {
    test('opens one stream per system for the talkgroups rules need', () {
      addDevice('d1', [
        ruleJson(talkgroups: [1, 2]),
        ruleJson(id: 'r2', system: 'other', talkgroups: [9]),
      ]);
      addDevice('d2', [
        ruleJson(talkgroups: [2, 3]),
      ]);
      addDevice('d3', [
        ruleJson(talkgroups: [4], enabled: false),
      ]);
      addDevice('d4', [
        ruleJson(talkgroups: [5]),
      ], paused: true);
      relay.refreshStreams();

      final bySystem = {for (final s in running()) s.system: s.talkgroups};
      expect(bySystem, {
        'sys': [1, 2, 3],
        'other': [9],
      });

      // Nothing changed, so nothing reconnects.
      relay.refreshStreams();
      expect(streams, hasLength(2));

      store.devices.remove('d2');
      relay.refreshStreams();
      expect({for (final s in running()) s.system: s.talkgroups}['sys'], [
        1,
        2,
      ]);

      store.devices.remove('d1');
      relay.refreshStreams();
      expect(running(), isEmpty);
    });

    test('a timed pause ends by itself', () {
      addDevice(
        'd1',
        [ruleJson()],
        paused: true,
        pausedUntil: now.add(Duration(minutes: 30)),
      );
      relay.refreshStreams();
      expect(running(), isEmpty);
      now = now.add(Duration(minutes: 31));
      relay.refreshStreams();
      expect(running(), hasLength(1));
    });

    test('every-call rules get the call and then its transcript', () async {
      addDevice('d1', [ruleJson(name: 'Dispatch')]);
      await relay.handleEvent('sys', upload('c1', 1));
      await relay.handleEvent('sys', transcript('c1', 1, 'Engine 5 respond'));

      expect(push.sent, hasLength(2));
      final (token, call) = push.sent.first;
      expect(token, 'token-d1');
      expect(call['type'], 'call');
      expect(call['talkgroupName'], 'TG1');
      expect(call['notificationId'], 'c1');
      expect(call['rules'], 'Dispatch');
      expect(push.sent.last.$2['text'], 'Engine 5 respond');
      expect(push.sent.last.$2['talkgroupName'], 'Live Name');
    });

    test('transcript rules skip the bare call', () async {
      addDevice('d1', [ruleJson(mode: 'transcripts')]);
      await relay.handleEvent('sys', upload('c1', 1));
      expect(push.sent, isEmpty);
      await relay.handleEvent('sys', transcript('c1', 1, 'hello'));
      expect(push.sent.single.$2['type'], 'transcript');
    });

    test('keyword rules only fire on a match, and say which matched', () async {
      addDevice('d1', [
        ruleJson(name: 'Fires', mode: 'keywords', keywords: ['fire', 'smoke']),
        ruleJson(id: 'r2', name: 'MVAs', mode: 'keywords', keywords: ['mva']),
      ]);
      await relay.handleEvent('sys', transcript('c1', 1, 'nothing here'));
      await relay.handleEvent('sys', transcript('c2', 2, 'fire on TG2'));
      expect(push.sent, isEmpty);

      await relay.handleEvent(
        'sys',
        transcript('c3', 1, 'Smoke and fire, MVA'),
      );
      final data = push.sent.single.$2;
      expect(data['rules'], 'Fires, MVAs');
      expect(data['keywords'], 'fire, smoke, mva');
    });

    test('paused phones and other systems get nothing', () async {
      addDevice('d1', [ruleJson()], paused: true);
      addDevice('d2', [ruleJson(system: 'other')]);
      await relay.handleEvent('sys', upload('c1', 1));
      expect(push.sent, isEmpty);
    });

    test('a repeated or re-uploaded call is pushed once', () async {
      addDevice('d1', [ruleJson()]);
      await relay.handleEvent('sys', upload('c1', 1));
      await relay.handleEvent('sys', upload('c1', 1));
      await relay.handleEvent('sys', upload('c2', 1, replaces: ['c1']));
      expect(push.sent, hasLength(1));

      // Its transcript updates the first call's notification.
      await relay.handleEvent('sys', transcript('c2', 1, 'text'));
      expect(push.sent.last.$2['notificationId'], 'c1');
      expect(push.sent.last.$2['callId'], 'c2');
    });

    test('long transcripts are cut short', () async {
      addDevice('d1', [ruleJson(mode: 'transcripts')]);
      await relay.handleEvent('sys', transcript('c1', 1, 'a' * 5000));
      expect(push.sent.single.$2['text']!.length, maxPushText + 1);
    });

    test('a phone with a dead token is dropped', () async {
      addDevice('d1', [ruleJson()]);
      relay.refreshStreams();
      push.result = PushResult.invalidToken;
      await relay.handleEvent('sys', upload('c1', 1));
      expect(store.devices, isEmpty);
      expect(running(), isEmpty);
    });

    test('many matching rules still fit in one push', () async {
      addDevice('d1', [
        for (var i = 0; i < 50; i++)
          ruleJson(
            id: 'r$i',
            name: 'A rule with a long name, number $i' * 2,
            mode: 'keywords',
            keywords: ['fire', 'keyword$i'],
          ),
      ]);
      await relay.handleEvent('sys', transcript('c1', 1, 'fire ' * 1000));
      final data = push.sent.single.$2;
      expect(data['rules']!.length, lessThanOrEqualTo(200));
      expect(utf8.encode(jsonEncode(data)).length, lessThan(4096 - 200));
    });

    test('malformed events are ignored', () async {
      addDevice('d1', [ruleJson()]);
      await relay.handleEvent('sys', {'upload': 'nope'});
      await relay.handleEvent('sys', {
        'transcript': {'callId': 'c1'},
      });
      await relay.handleEvent('sys', transcript('c1', 1, '   '));
      expect(push.sent, isEmpty);
    });
  });

  group('api', () {
    late Handler api;
    late String alice;
    late String bob;

    setUp(() {
      api = buildApi(relay);
      alice = store.createKey('alice').$2;
      bob = store.createKey('bob').$2;
    });

    Future<(int, Map<String, dynamic>)> call(
      String method,
      String path, {
      String? key,
      Object? body,
    }) async {
      final response = await api(
        Request(
          method,
          Uri.parse('http://relay$path'),
          headers: {if (key != null) 'authorization': 'Bearer $key'},
          body: body == null ? null : jsonEncode(body),
        ),
      );
      return (
        response.statusCode,
        jsonDecode(await response.readAsString()) as Map<String, dynamic>,
      );
    }

    const device = '/v1/devices/abcdefghijklmnop';
    Map<String, dynamic> setup({List<Object>? rules, bool paused = false}) => {
      'token': 'fcm-token',
      'rules': rules ?? [ruleJson()],
      'paused': paused,
      'pausedUntil': null,
    };

    test('needs a valid key, except the health check', () async {
      expect((await call('GET', '/v1/status')).$1, 401);
      expect((await call('GET', '/v1/status', key: 'ccr_wrong')).$1, 401);
      expect((await call('GET', '/healthz')).$1, 200);

      final (status, body) = await call('GET', '/v1/status', key: alice);
      expect(status, 200);
      expect(body['keyName'], 'alice');
      expect(body['push'], 'fake');
    });

    test('a phone registers, updates, and unsubscribes', () async {
      expect((await call('PUT', device, key: alice, body: setup())).$1, 200);
      expect(store.devices.values.single.rules.single.talkgroups, {1: 'TG1'});
      expect(running().single.talkgroups, [1]);

      final paused = setup(
        rules: [
          ruleJson(talkgroups: [1, 2]),
        ],
        paused: true,
      );
      expect((await call('PUT', device, key: alice, body: paused)).$1, 200);
      expect(store.devices.values.single.paused, isTrue);
      expect(running(), isEmpty);

      expect((await call('DELETE', device, key: alice)).$1, 200);
      expect(store.devices, isEmpty);
      // Unsubscribing twice is fine.
      expect((await call('DELETE', device, key: alice)).$1, 200);
    });

    test('another key can\'t change or remove a phone', () async {
      await call('PUT', device, key: alice, body: setup());
      expect((await call('PUT', device, key: bob, body: setup())).$1, 403);
      expect((await call('DELETE', device, key: bob)).$1, 403);
      expect(store.devices, hasLength(1));
    });

    test('bad setups are refused with a reason', () async {
      Future<String> refusal(Object body, {String path = device}) async {
        final (status, json) = await call('PUT', path, key: alice, body: body);
        expect(status, 400);
        return json['error'];
      }

      expect(
        await refusal(setup(), path: '/v1/devices/short'),
        contains('device ID'),
      );
      expect(await refusal({...setup(), 'token': ''}), contains('token'));
      expect(
        await refusal(setup(rules: [ruleJson(mode: 'keywords')])),
        contains('keyword'),
      );
      expect(await refusal([]), contains('object'));
      expect(
        await refusal({...setup(), 'pausedUntil': 'soon'}),
        contains('pausedUntil'),
      );
      expect(store.devices, isEmpty);
    });

    test('one key can only register so many phones', () async {
      final limited = buildApi(relay, maxDevicesPerKey: 2);
      Future<int> register(String id) async => (await limited(
        Request(
          'PUT',
          Uri.parse('http://relay/v1/devices/$id'),
          headers: {'authorization': 'Bearer $alice'},
          body: jsonEncode(setup()),
        ),
      )).statusCode;

      expect(await register('aaaaaaaaaaaaaaaa1'), 200);
      expect(await register('aaaaaaaaaaaaaaaa2'), 200);
      expect(await register('aaaaaaaaaaaaaaaa3'), 403);
      // Updating an existing phone is still fine.
      expect(await register('aaaaaaaaaaaaaaaa1'), 200);
    });

    test('rules can only cover so many systems, and pauses are sane', () async {
      final rules = [
        for (var i = 0; i <= maxSystemsPerDevice; i++)
          ruleJson(id: 'r$i', system: 'sys$i'),
      ];
      final (status, body) = await call(
        'PUT',
        device,
        key: alice,
        body: setup(rules: rules),
      );
      expect(status, 400);
      expect(body['error'], contains('systems'));

      for (final until in [-1, 99999999999999, 'soon']) {
        final (status, _) = await call(
          'PUT',
          device,
          key: alice,
          body: {...setup(), 'paused': true, 'pausedUntil': until},
        );
        expect(status, 400);
      }
    });

    test('a test push reaches the phone', () async {
      expect((await call('POST', '$device/test', key: alice)).$1, 404);
      await call('PUT', device, key: alice, body: setup());
      final (status, _) = await call('POST', '$device/test', key: alice);
      expect(status, 200);
      expect(push.sent.single.$2['type'], 'test');
    });
  });
}

String keysFileText(RelayStore store) => store.keysFile.readAsStringSync();
