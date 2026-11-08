import 'dart:async';
import 'package:clearcut_core/sse_service.dart';
import 'package:collection/collection.dart';

import 'push.dart';
import 'rules.dart';
import 'store.dart';

/// A live connection to one system's call stream.
abstract class EventStream {
  void start();
  void stop();
}

typedef StreamFactory =
    EventStream Function(
      String systemId,
      List<int> talkgroups,
      void Function(Map<String, dynamic>) onEvent,
    );

class _SseEventStream implements EventStream {
  final SSEService _service;
  _SseEventStream(this._service);

  @override
  void start() => _service.start();

  @override
  void stop() => _service.stop();
}

EventStream clearcutStream(
  String systemId,
  List<int> talkgroups,
  void Function(Map<String, dynamic>) onEvent,
) => _SseEventStream(
  SSEService(systemName: systemId, talkgroupIds: talkgroups, onEvent: onEvent),
);

/// Transcripts longer than this are cut short, to stay well inside FCM's
/// 4 KB message limit.
const maxPushText = 1500;

/// Shortens [text] so many matched rules can't push a message past FCM's
/// 4 KB limit, which would make the push fail.
String _cap(String text, int length) =>
    text.length > length ? '${text.substring(0, length - 1)}…' : text;

/// How many recent calls are remembered, to link transcripts and re-uploads
/// back to the call they belong to.
const _recentCallLimit = 5000;

class Relay {
  final RelayStore store;
  final PushSender push;
  final StreamFactory streamFactory;
  DateTime Function() now;

  Relay(
    this.store,
    this.push, {
    this.streamFactory = clearcutStream,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final _streams = <String, (Set<int>, EventStream)>{};
  final _timers = <Timer>[];

  /// Call ID to the first call ID it replaced, so a re-uploaded call updates
  /// the same notification on the phone instead of adding another.
  final _rootCallIds = <String, String>{};

  /// Calls that were already pushed, per phone, so a repeated event isn't
  /// pushed twice.
  final _pushed = <String>{};

  Map<String, Set<int>> get watchedTalkgroups {
    final watched = <String, Set<int>>{};
    final time = now();
    for (final device in store.devices.values) {
      if (!device.isActive(time)) continue;
      for (final rule in device.rules) {
        if (!rule.enabled) continue;
        watched
            .putIfAbsent(rule.systemId, () => {})
            .addAll(rule.talkgroups.keys);
      }
    }
    return watched;
  }

  bool get isWatching => _streams.isNotEmpty;

  void start() {
    refreshStreams();
    // Picks up paused phones whose pause ran out.
    _timers.add(Timer.periodic(Duration(minutes: 1), (_) => refreshStreams()));
    // Applies keys revoked with the command-line tool.
    _timers.add(Timer.periodic(Duration(seconds: 15), (_) => checkKeys()));
  }

  void stop() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final (_, stream) in _streams.values) {
      stream.stop();
    }
    _streams.clear();
  }

  void checkKeys() {
    if (store.reloadKeys() && store.removeOrphanedDevices()) refreshStreams();
  }

  /// Opens, changes, or closes streams so exactly the talkgroups some active
  /// rule needs are watched.
  void refreshStreams() {
    final wanted = watchedTalkgroups;
    for (final system in _streams.keys.toList()) {
      final (current, stream) = _streams[system]!;
      final next = wanted[system];
      if (next == null || !const SetEquality().equals(current, next)) {
        stream.stop();
        _streams.remove(system);
      }
    }
    for (final MapEntry(key: system, value: talkgroups) in wanted.entries) {
      if (_streams.containsKey(system)) continue;
      final sorted = talkgroups.toList()..sort();
      final stream = streamFactory(
        system,
        sorted,
        (event) => handleEvent(system, event),
      );
      _streams[system] = (talkgroups, stream);
      stream.start();
      print('Watching ${sorted.length} talkgroups on $system');
    }
  }

  void _remember(String callId, String rootId) {
    _rootCallIds[callId] = rootId;
    if (_rootCallIds.length > _recentCallLimit) {
      _rootCallIds.remove(_rootCallIds.keys.first);
    }
  }

  /// Returns whether [key] was new.
  bool _markPushed(String key) {
    if (!_pushed.add(key)) return false;
    if (_pushed.length > _recentCallLimit * 4) _pushed.remove(_pushed.first);
    return true;
  }

  /// Matches one stream event to every active phone's rules and pushes it.
  /// Returns when every push has been attempted.
  Future<void> handleEvent(String system, Map<String, dynamic> event) async {
    final upload = event['upload'];
    final transcript = event['transcript'];

    final String kind;
    final String callId;
    final int talkgroup;
    String text = '';
    String? talkgroupName;
    int? startTime;

    if (upload is Map && upload['id'] is String && upload['talkgroup'] is int) {
      kind = 'call';
      callId = upload['id'];
      talkgroup = upload['talkgroup'];
      startTime = upload['startTime'] is int ? upload['startTime'] : null;
      final replaced = upload['replacesCallIds'];
      final firstReplaced = replaced is List
          ? replaced.whereType<String>().firstOrNull
          : null;
      _remember(callId, _rootCallIds[firstReplaced] ?? firstReplaced ?? callId);
    } else if (transcript is Map &&
        transcript['callId'] is String &&
        transcript['talkgroup'] is int) {
      kind = 'transcript';
      callId = transcript['callId'];
      talkgroup = transcript['talkgroup'];
      text = (transcript['text'] as String? ?? '').trim();
      talkgroupName = transcript['talkgroupName'] as String?;
      if (text.isEmpty) return;
    } else {
      return;
    }

    final rootId = _rootCallIds[callId] ?? callId;
    final time = now();
    final sends = <Future<void>>[];

    for (final device in store.devices.values.toList()) {
      if (!device.isActive(time)) continue;

      final matched = <Rule>[];
      final keywords = <String>{};
      for (final rule in device.rules) {
        if (!rule.watches(system, talkgroup)) continue;
        if (kind == 'call') {
          if (rule.mode == RuleMode.all) matched.add(rule);
        } else if (rule.mode == RuleMode.keywords) {
          final found = rule.matchingKeywords(text);
          if (found.isNotEmpty) {
            matched.add(rule);
            keywords.addAll(found);
          }
        } else {
          matched.add(rule);
        }
      }
      if (matched.isEmpty) continue;

      // A re-uploaded call is the same call, so it isn't announced again.
      if (!_markPushed('${device.id}|$kind|$rootId')) continue;

      final data = {
        'type': kind,
        'callId': callId,
        'notificationId': rootId,
        'systemId': system,
        'talkgroupId': '$talkgroup',
        'talkgroupName': _cap(
          talkgroupName ??
              matched.first.talkgroups[talkgroup] ??
              'Talkgroup $talkgroup',
          200,
        ),
        'text': text.length > maxPushText
            ? '${text.substring(0, maxPushText)}…'
            : text,
        'rules': _cap(matched.map((rule) => rule.name).join(', '), 200),
        'keywords': _cap(keywords.join(', '), 200),
        if (startTime != null) 'startTime': '$startTime',
      };
      sends.add(sendTo(device, data));
    }
    await Future.wait(sends);
  }

  /// Sends one push, dropping the phone if its token is no longer valid.
  Future<PushResult> sendTo(Device device, Map<String, String> data) async {
    final result = await push.send(device.token, data);
    if (result == PushResult.invalidToken) {
      print('Removing device ${device.id}: its push token is no longer valid');
      store.devices.remove(device.id);
      store.scheduleSave();
      refreshStreams();
    } else if (result == PushResult.sent) {
      device.lastPush = now();
      store.scheduleSave();
    }
    return result;
  }
}
