// Makes the Google Play listing's screenshots and feature graphic from the
// real app pages, with made-up data, so no real radio traffic is shown.
//
//   flutter test tool/store_assets/store_assets_test.dart
//
// Images are written to play-store/. The icon is made separately; see
// play-store/README.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/services/notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const outDir = 'play-store';

// A 1080x1920 phone screen.
const dpr = 2.625;
const logicalSize = Size(1080 / dpr, 1920 / dpr);
const statusBarHeight = 24.0;

final rootKey = GlobalKey();

// --- Made-up data ------------------------------------------------------------

const systemId = 'lakeview-county';

final systems = [
  {
    'id': systemId,
    'name': 'Lakeview County',
    'description': 'Fire, EMS and sheriff dispatch',
  },
  {
    'id': 'riverside-city',
    'name': 'Riverside City',
    'description': 'Police and fire, all districts',
  },
  {
    'id': 'north-valley',
    'name': 'North Valley Regional',
    'description': 'Countywide interoperability',
  },
  {
    'id': 'harbor-port',
    'name': 'Harbor Port Authority',
    'description': 'Port operations and security',
  },
  {
    'id': 'metro-transit',
    'name': 'Metro Transit',
    'description': 'Bus and rail operations',
  },
  {
    'id': 'pine-ridge',
    'name': 'Pine Ridge Township',
    'description': 'Fire and public works',
  },
];

Map<String, dynamic> tg(int id, String name, String description,
        {bool transcribe = true}) =>
    {
      'id': id,
      'name': name,
      'description': description,
      'transcribe': transcribe,
    };

final talkgroups = [
  tg(1001, 'Fire Dispatch', 'Countywide fire dispatch'),
  tg(1002, 'Fire Tac 2', 'Fireground tactical', transcribe: false),
  tg(1003, 'EMS Dispatch', 'Ambulance dispatch and hospital notifications'),
  tg(1010, 'Sheriff Dispatch', 'Sheriff\'s office, all zones'),
  tg(1011, 'Sheriff Car-to-Car', 'Unit to unit', transcribe: false),
  tg(1020, 'Highway Department', 'Plows and road crews'),
  tg(1030, 'Hospital Operations', 'Lakeview General and Mercy'),
  tg(1040, 'Countywide Events', 'Special events and mutual aid'),
  tg(1050, 'Emergency Management', 'EOC and weather operations'),
];

final fireDispatch = talkgroups[0];
final emsDispatch = talkgroups[2];

int at(int hour, int minute, int second) =>
    DateTime(2026, 11, 23, hour, minute, second).millisecondsSinceEpoch ~/
    1000;

Map<String, dynamic> call(String id, int talkgroup, int start, int seconds,
        String? transcript) =>
    {
      'id': id,
      'talkgroup': talkgroup,
      'startTime': start,
      'endTime': start + seconds,
      'audioFile': 'audio/$systemId/$talkgroup/$start-$id.m4a',
      'transcript': transcript == null ? null : {'text': transcript},
    };

final calls = [
  call('c6', 1001, at(14, 6, 41), 7,
      'Engine 12 to Lakeview, we are on scene, two-story residential, light '
          'smoke showing from the second floor. Engine 12 will be Maple '
          'Command.'),
  call('c5', 1003, at(14, 5, 12), 4, 'Medic 7 en route, ETA six minutes.'),
  call('c4', 1001, at(14, 3, 58), 11,
      'Engine 12, Ladder 4, Medic 7, respond to a reported structure fire, '
          '400 block of Maple Avenue. Caller reports smoke from an upstairs '
          'window.'),
  call('c3', 1003, at(13, 58, 20), 3, null),
  call('c2', 1003, at(13, 51, 7), 5,
      'Lakeview, Medic 3, we\'re clear at Lakeview General and back in '
          'service.'),
  call('c1', 1001, at(13, 47, 33), 6,
      'Lakeview, Engine 5. We\'ll be out of quarters for fuel, available on '
          'the radio.'),
];

Map<String, dynamic> favorite(String system, List<Map<String, dynamic>> tgs) =>
    {
      'systemId': system,
      'talkgroups': [
        for (final t in tgs) {'id': t['id'], 'name': t['name']}
      ],
    };

final favorites = [
  favorite(systemId, [fireDispatch, emsDispatch]),
  favorite(systemId, [talkgroups[3]]),
  favorite('riverside-city', [
    {'id': 2001, 'name': 'Police Dispatch North'},
    {'id': 2002, 'name': 'Police Dispatch South'},
  ]),
  favorite('north-valley', [
    {'id': 3001, 'name': 'Regional Fire Mutual Aid'}
  ]),
  favorite(systemId, [talkgroups[8]]),
];

const relayHost = 'relay.example.com';

final rules = [
  AlertRule(
    id: 'rule-fire',
    name: 'Structure fires',
    systemId: systemId,
    systemName: 'Lakeview County',
    talkgroups: [
      {'id': 1001, 'name': 'Fire Dispatch'}
    ],
    mode: AlertMode.keywords,
    keywords: ['structure fire', 'working fire', 'mutual aid'],
  ),
  AlertRule(
    id: 'rule-ems',
    name: 'EMS Dispatch',
    systemId: systemId,
    systemName: 'Lakeview County',
    talkgroups: [
      {'id': 1003, 'name': 'EMS Dispatch'}
    ],
    mode: AlertMode.transcripts,
  ),
];

// --- Fakes ---------------------------------------------------------------------

final streams = <StreamController<List<int>>>[];

final client = MockClient.streaming((request, _) async {
  final path = request.url.path;
  Object? body;
  if (request.url.host == relayHost) {
    body = path == '/v1/status'
        ? {
            'ok': true,
            'apiVersion': 1,
            'keyName': 'alex',
            'push': 'fcm',
          }
        : {'ok': true};
  } else if (path.endsWith('/stream')) {
    final controller = StreamController<List<int>>();
    streams.add(controller);
    return http.StreamedResponse(controller.stream, 200);
  } else if (path.endsWith('/systems')) {
    body = systems;
  } else if (path.endsWith('/talkgroups')) {
    body = talkgroups;
  } else if (path.endsWith('/calls')) {
    body = request.url.queryParameters.containsKey('before_ts') ? [] : calls;
  }
  return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))), 200);
});

class FakePush implements PushService {
  @override
  bool get available => true;
  @override
  Future<String?> getToken() async => 'push-token';
  @override
  Stream<String> get onTokenRefresh => Stream.empty();
  @override
  Stream<Map<String, String>> get onMessage => Stream.empty();
  @override
  Future<bool> requestPermission() async => true;
}

// --- Rendering -----------------------------------------------------------------

Future<void> loadFonts() async {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/flutter'}'
      '/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(await File('$fonts/$name').readAsBytes());
  await (FontLoader('Roboto')
        ..addFont(read('Roboto-Regular.ttf'))
        ..addFont(read('Roboto-Medium.ttf'))
        ..addFont(read('Roboto-Bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(read('MaterialIcons-Regular.otf')))
      .load();
}

/// An Android-style status bar, so screenshots look like a phone.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
        fontFamily: 'Roboto',
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w500);
    return const SizedBox(
      height: statusBarHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text('2:07', style: style),
            Spacer(),
            Icon(Icons.signal_cellular_alt, color: Colors.white, size: 15),
            SizedBox(width: 4),
            Icon(Icons.wifi, color: Colors.white, size: 15),
            SizedBox(width: 4),
            Icon(Icons.battery_full, color: Colors.white, size: 15),
          ],
        ),
      ),
    );
  }
}

void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = logicalSize * dpr;
  tester.view.devicePixelRatio = dpr;
  tester.view.padding = FakeViewPadding(top: statusBarHeight * dpr);
  tester.view.viewPadding = FakeViewPadding(top: statusBarHeight * dpr);
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(WidgetTester tester) async {
  usePhoneScreen(tester);
  await tester.pumpWidget(RepaintBoundary(
    key: rootKey,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          MyApp(push: FakePush()),
          const Positioned(top: 0, left: 0, right: 0, child: StatusBar()),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Saves what's on screen as a PNG. Play wants screenshots and the feature
/// graphic without an alpha channel, and the icon with one.
Future<void> save(WidgetTester tester, String name,
    {double pixelRatio = dpr, bool alpha = false}) async {
  await tester.pumpAndSettle();
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(rootKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final file = File('$outDir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(encodePng(
        image.width, image.height, rgba!.buffer.asUint8List(),
        alpha: alpha));
    print('Wrote ${file.path} (${image.width}x${image.height}, '
        '${alpha ? '32' : '24'}-bit)');
  });
}

/// A minimal PNG encoder: 8-bit RGB or RGBA, no filtering.
List<int> encodePng(int width, int height, Uint8List rgba,
    {required bool alpha}) {
  final channels = alpha ? 4 : 3;
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // No filter on this row.
    final row = Uint8List(width * channels);
    for (var x = 0; x < width; x++) {
      final from = (y * width + x) * 4;
      final to = x * channels;
      row[to] = rgba[from];
      row[to + 1] = rgba[from + 1];
      row[to + 2] = rgba[from + 2];
      if (alpha) row[to + 3] = rgba[from + 3];
    }
    raw.add(row);
  }

  List<int> chunk(String type, List<int> data) {
    final typed = [...ascii.encode(type), ...data];
    return [..._uint32(data.length), ...typed, ..._uint32(_crc32(typed))];
  }

  return [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    ...chunk('IHDR', [
      ..._uint32(width),
      ..._uint32(height),
      8, // bits per channel
      alpha ? 6 : 2, // RGBA or RGB
      0, 0, 0, // compression, filter, interlace
    ]),
    ...chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes())),
    ...chunk('IEND', []),
  ];
}

List<int> _uint32(int value) =>
    [value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// Ends the page's live stream, so no timers outlive the test.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // Not awaited: a stream nobody listens to any more never finishes closing.
  for (final stream in streams) {
    unawaited(stream.close());
  }
  streams.clear();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> openDrawerItem(WidgetTester tester, String item) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, item));
  await tester.pumpAndSettle();
}

/// Lets a snack bar time out, so it isn't in the next screenshot.
Future<void> clearMessages(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // No DEBUG banner in store screenshots.
    WidgetsApp.debugAllowBannerOverride = false;
    await loadFonts();
  });

  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({
      'favorites': jsonEncode(favorites),
      notificationPrefsKey: jsonEncode({
        'address': relayHost,
        'port': null,
        'key': 'ccr_example',
        'subscribed': true,
        'paused': false,
        'rules': [for (final rule in rules) rule.toJson()],
      }),
    });
  });

  testWidgets('systems, talkgroups, stream and call actions', (tester) async {
    await http.runWithClient(() async {
      await pumpApp(tester);
      await save(tester, '04-systems');

      await tester.tap(find.text('Lakeview County'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump();
      await save(tester, '03-talkgroups');

      await tester.tap(find.text('Listen to Selected (2)'));
      await tester.pumpAndSettle();
      await save(tester, '01-stream');

      await tester.longPress(find.textContaining('Engine 12 to Lakeview'));
      await tester.pumpAndSettle();
      await save(tester, '02-call-actions');

      await tester.tap(find.text('Correct Transcript'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).last,
          'Engine 12 to Lakeview, we are on scene, two-story residential, '
          'light smoke showing from the second floor. Engine 12 will be '
          'Maple Avenue Command.');
      await tester.pumpAndSettle();
      // The cursor blinks; settle on a frame without it.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await save(tester, '08-correct-transcript');

      await finish(tester);
    }, () => client);
  });

  testWidgets('favorites', (tester) async {
    await http.runWithClient(() async {
      await pumpApp(tester);
      await openDrawerItem(tester, 'Favorites');
      await save(tester, '06-favorites');
      await finish(tester);
    }, () => client);
  });

  testWidgets('alert rule', (tester) async {
    await http.runWithClient(() async {
      await pumpApp(tester);
      await openDrawerItem(tester, 'Settings');
      // Scrolled past the rule, so it's well clear of the app bar.
      await tester.scrollUntilVisible(find.text('Add Rule'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('Structure fires'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Structure fires'));
      await tester.pumpAndSettle();
      await save(tester, '05-alert-rule');
      await finish(tester);
    }, () => client);
  });

  testWidgets('start page', (tester) async {
    await http.runWithClient(() async {
      await pumpApp(tester);
      await openDrawerItem(tester, 'Settings');
      await tester.tap(find.text('Start Page'));
      await tester.pumpAndSettle();
      await save(tester, '07-start-page');
      await finish(tester);
    }, () => client);
  });

  testWidgets('icon', (tester) async {
    tester.view.physicalSize = const Size(512, 512);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final icon = MemoryImage(File(
            'android/app/src/main/res/mipmap-xxxhdpi/cc_icon.png')
        .readAsBytesSync());
    // Full bleed on white, the launcher icon's background: Play rounds the
    // corners itself.
    await tester.pumpWidget(RepaintBoundary(
      key: rootKey,
      child: ColoredBox(
        color: Colors.white,
        child: Image(image: icon, width: 512, height: 512),
      ),
    ));
    await tester.runAsync(() async {
      await precacheImage(icon, tester.element(find.byType(Image)));
    });
    await tester.pump();
    await save(tester, 'icon-512', pixelRatio: 1, alpha: true);
  });

  testWidgets('feature graphic', (tester) async {
    tester.view.physicalSize = const Size(1024, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final icon = MemoryImage(File(
            'android/app/src/main/res/mipmap-xxxhdpi/cc_icon.png')
        .readAsBytesSync());
    final stream = MemoryImage(File('$outDir/01-stream.png').readAsBytesSync());

    await tester.pumpWidget(RepaintBoundary(
      key: rootKey,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: FeatureGraphic(icon: icon, screenshot: stream),
      ),
    ));
    await tester.runAsync(() async {
      final context = tester.element(find.byType(FeatureGraphic));
      await precacheImage(icon, context);
      await precacheImage(stream, context);
    });
    await tester.pump();
    await save(tester, 'feature-graphic', pixelRatio: 1);
  });
}

class FeatureGraphic extends StatelessWidget {
  final ImageProvider icon;
  final ImageProvider screenshot;

  const FeatureGraphic(
      {super.key, required this.icon, required this.screenshot});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
        seedColor: Colors.greenAccent, brightness: Brightness.dark);
    return Container(
      width: 1024,
      height: 500,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF1E2A3A), scheme.surface],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 72,
            top: 0,
            bottom: 0,
            width: 520,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The logo is navy on transparent, so it sits on a white
                // tile, as it does as a launcher icon.
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Image(image: icon, width: 120, height: 120),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Clearcut Mobile',
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Live radio, transcripts and alerts',
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 28,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          // A phone showing the stream, cut off by the bottom edge.
          Positioned(
            right: 70,
            top: 48,
            child: Container(
              width: 300,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(36),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54, blurRadius: 40, offset: Offset(0, 16)),
                ],
              ),
              padding: const EdgeInsets.all(10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image(image: screenshot, width: 280),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
