import 'dart:async';
import 'dart:convert';

import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/favorites_page.dart';
import 'package:clearcut_mobile/pages/info_page.dart';
import 'package:clearcut_mobile/pages/listener_page.dart';
import 'package:clearcut_mobile/pages/systems_page.dart';
import 'package:clearcut_mobile/services/call_utils.dart';
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
  List<Map<String, dynamic>> latestCalls = [];
  // Handed out one per before_ts request, then empty: the end of history.
  List<List<Map<String, dynamic>>> olderPages = [];
  bool failCalls = false;
  bool failOlderCalls = false;
  final streams = <StreamController<List<int>>>[];

  void send(Map<String, dynamic> event) {
    streams.last.add(utf8.encode('data:${jsonEncode(event)}\n\n'));
  }

  late final client = MockClient.streaming((request, _) async {
    final path = request.url.path;
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
      body = talkgroups;
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
