import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clearcut_core/call_utils.dart';

import 'bans.dart';

/// Transcript corrections sent from the app, for retraining transcription.
///
/// Anyone with the app can send these, without an access key, so everything
/// here assumes the sender may be a bot: requests are small, strictly
/// checked, and limited per IP address, per install, and overall.

final _installIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

bool isValidInstallId(String id) => _installIdPattern.hasMatch(id);
final _callIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final _audioFilePattern = RegExp(r'^audio/[A-Za-z0-9._/-]{1,500}$');
final _appVersionPattern = RegExp(r'^[A-Za-z0-9.+_-]{1,32}$');

// Control characters other than tab and newline.
final _controlCharacters = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');

// Radio traffic doesn't contain web links, but spam does.
final _links = RegExp(r'https?://|www\.', caseSensitive: false);

const maxTranscriptLength = 4000;

/// The largest correction request accepted, well above what a real one needs.
const maxCorrectionBodyBytes = 16 * 1024;

/// A correction that passed every check, as written to the log.
class Correction {
  final String id;
  final DateTime receivedAt;
  final String installId;

  /// The sender's address, as limited and banned: IPv6 as its /64.
  final String ip;
  final String? appVersion;
  final String callId;
  final String systemId;
  final int? talkgroupId;
  final String? audioFile;
  final String original;
  final String corrected;
  final DateTime? submittedAt;

  Correction({
    required this.id,
    required this.receivedAt,
    required this.installId,
    required this.ip,
    required this.appVersion,
    required this.callId,
    required this.systemId,
    required this.talkgroupId,
    required this.audioFile,
    required this.original,
    required this.corrected,
    required this.submittedAt,
  });

  /// The log's format. Every line has every key, so readers needn't guess.
  Map<String, dynamic> toJson() => {
    'id': id,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'installId': installId,
    'ip': ip,
    'appVersion': appVersion,
    'callId': callId,
    'systemId': systemId,
    'talkgroupId': talkgroupId,
    'audioFile': audioFile,
    'audioUrl': audioFile == null ? null : audioUrlFor(audioFile!),
    'originalTranscript': original,
    'correctedTranscript': corrected,
    'submittedAt': submittedAt?.toUtc().toIso8601String(),
  };
}

/// Checks a correction from the app. Throws [FormatException] with a reason
/// the app can show, or log, if anything is off.
Correction parseCorrection(
  Object? body, {
  required String id,
  required DateTime receivedAt,
  required String ip,
}) {
  if (body is! Map) throw FormatException('Expected a JSON object.');

  String? optionalString(String field, RegExp pattern) {
    final value = body[field];
    if (value == null) return null;
    if (value is! String || !pattern.hasMatch(value)) {
      throw FormatException('Invalid $field.');
    }
    return value;
  }

  String transcript(String field, {required bool required}) {
    final value = body[field] ?? (required ? null : '');
    if (value is! String) throw FormatException('$field is required.');
    final text = value.trim();
    if (text.length > maxTranscriptLength) {
      throw FormatException(
        '$field is longer than $maxTranscriptLength characters.',
      );
    }
    if (_controlCharacters.hasMatch(text)) {
      throw FormatException('$field contains control characters.');
    }
    return text;
  }

  final installId = body['installId'];
  if (installId is! String || !_installIdPattern.hasMatch(installId)) {
    throw FormatException('Invalid installId.');
  }
  final callId = body['callId'];
  if (callId is! String || !_callIdPattern.hasMatch(callId)) {
    throw FormatException('Invalid callId.');
  }
  final systemId = body['systemId'];
  if (systemId is! String || !isValidSystemId(systemId)) {
    throw FormatException('Invalid systemId.');
  }
  final talkgroupId = body['talkgroupId'];
  if (talkgroupId != null &&
      (talkgroupId is! int || talkgroupId < 0 || talkgroupId > 0x7fffffff)) {
    throw FormatException('Invalid talkgroupId.');
  }
  final audioFile = optionalString('audioFile', _audioFilePattern);
  if (audioFile != null && audioFile.split('/').contains('..')) {
    throw FormatException('Invalid audioFile.');
  }

  final original = transcript('originalTranscript', required: false);
  final corrected = transcript('correctedTranscript', required: true);
  if (corrected.isEmpty) {
    throw FormatException('correctedTranscript is empty.');
  }
  if (corrected == original) {
    throw FormatException('The correction is the same as the transcript.');
  }
  if (_links.hasMatch(corrected)) {
    throw FormatException('Corrections can\'t contain links.');
  }

  final submitted = body['submittedAt'];
  return Correction(
    id: id,
    receivedAt: receivedAt,
    installId: installId,
    ip: ip,
    appVersion: optionalString('appVersion', _appVersionPattern),
    callId: callId,
    systemId: systemId,
    talkgroupId: talkgroupId as int?,
    audioFile: audioFile,
    original: original,
    corrected: corrected,
    submittedAt: submitted is String ? DateTime.tryParse(submitted) : null,
  );
}

/// Counts requests in fixed windows, such as per hour.
///
/// Memory is bounded: the counts are cleared every window, and callers only
/// count a request once it's passed the overall limit, so there can be no
/// more entries than that limit allows.
class WindowCounter {
  final int limit;
  final Duration window;
  final _counts = <String, int>{};
  DateTime? _windowStart;

  WindowCounter({required this.limit, required this.window});

  void _roll(DateTime now) {
    final start = _windowStart;
    if (start == null || now.difference(start) >= window) {
      _counts.clear();
      _windowStart = now;
    }
  }

  /// Whether [key] is still under its limit. Doesn't count anything.
  bool allows(String key, DateTime now) {
    _roll(now);
    return (_counts[key] ?? 0) < limit;
  }

  void count(String key, DateTime now) {
    _roll(now);
    _counts[key] = (_counts[key] ?? 0) + 1;
  }

  /// When the current window ends, for Retry-After.
  Duration retryAfter(DateTime now) {
    _roll(now);
    return window - now.difference(_windowStart!);
  }

  void reset(String key) => _counts.remove(key);

  int get trackedKeys => _counts.length;
}

/// The limits on corrections. Each can be changed with an environment
/// variable; see the relay's README.
class CorrectionLimits {
  final int perIpPerHour;
  final int perInstallPerDay;
  final int totalPerDay;
  final int maxLogBytes;

  /// Refused requests in a day that get a sender banned automatically.
  final int strikesPerDay;

  const CorrectionLimits({
    this.perIpPerHour = 30,
    this.perInstallPerDay = 200,
    this.totalPerDay = 5000,
    this.maxLogBytes = 200 * 1024 * 1024,
    this.strikesPerDay = 10,
  });

  factory CorrectionLimits.fromEnvironment(Map<String, String> env) {
    int read(String name, int fallback) {
      final value = int.tryParse(env[name] ?? '');
      return value != null && value > 0 ? value : fallback;
    }

    const defaults = CorrectionLimits();
    return CorrectionLimits(
      perIpPerHour: read(
        'RELAY_CORRECTIONS_PER_IP_PER_HOUR',
        defaults.perIpPerHour,
      ),
      perInstallPerDay: read(
        'RELAY_CORRECTIONS_PER_INSTALL_PER_DAY',
        defaults.perInstallPerDay,
      ),
      totalPerDay: read('RELAY_CORRECTIONS_PER_DAY', defaults.totalPerDay),
      maxLogBytes:
          read('RELAY_CORRECTIONS_MAX_MB', defaults.maxLogBytes ~/ 1048576) *
          1048576,
      strikesPerDay: read('RELAY_CORRECTIONS_STRIKES', defaults.strikesPerDay),
    );
  }
}

/// Why a correction was turned away before it was read.
enum Refusal { overall, ip, install, full }

/// Keeps the corrections log, `corrections.jsonl`: one JSON object per line,
/// oldest first. A device that corrects the same call twice leaves two lines;
/// the later one is its final answer.
class CorrectionLog {
  final File file;
  final CorrectionLimits limits;
  final DateTime Function() now;

  late final _overall = WindowCounter(
    limit: limits.totalPerDay,
    window: Duration(days: 1),
  );
  late final _perIp = WindowCounter(
    limit: limits.perIpPerHour,
    window: Duration(hours: 1),
  );
  late final _perInstall = WindowCounter(
    limit: limits.perInstallPerDay,
    window: Duration(days: 1),
  );
  late final _strikes = {
    for (final kind in BanKind.values)
      kind: WindowCounter(
        limit: limits.strikesPerDay,
        window: Duration(days: 1),
      ),
  };

  final BanList bans;

  // Rejections are logged once per sender per window, so a flood can't fill
  // the server's logs either.
  final _reported = <String>{};
  DateTime? _reportedSince;

  CorrectionLog(
    Directory dir, {
    this.limits = const CorrectionLimits(),
    DateTime Function()? now,
  }) : file = File('${dir.path}/corrections.jsonl'),
       bans = BanList(dir),
       now = now ?? DateTime.now;

  /// How long each automatic ban lasts, by how many the sender has had.
  /// Installs end up banned for good; IP addresses don't, since a phone
  /// carrier can put many people behind one address.
  static Duration? autoBanLength(BanKind kind, int offenses) =>
      switch (offenses) {
        1 => Duration(days: 1),
        2 => Duration(days: 7),
        _ => kind == BanKind.ip ? Duration(days: 7) : null,
      };

  /// Whether [value] is banned. Requests from banned senders are answered as
  /// if accepted, and dropped.
  bool isBanned(BanKind kind, String value) {
    final ban = bans.active(kind, value, now());
    if (ban == null) return false;
    _report(
      'banned:${kind.name}:$value',
      'Ignoring corrections from banned ${_describe(kind, value)}',
    );
    return true;
  }

  /// Records a refused request against a sender. Enough in a day bans the
  /// sender automatically, for longer each time.
  void strike(BanKind kind, String value, String reason) {
    final time = now();
    if (bans.active(kind, value, time) != null) return;
    final counter = _strikes[kind]!;
    counter.count(value, time);
    if (counter.allows(value, time)) return;

    final previous = bans.find(kind, value);
    // Manual bans that have run out aren't counted, only automatic ones.
    final offenses = (previous?.automatic == true ? previous!.offenses : 0) + 1;
    final length = autoBanLength(kind, offenses);
    bans.add(
      Ban(
        kind: kind,
        value: value,
        reason:
            '${limits.strikesPerDay} refused requests in a day; '
            'last: $reason',
        created: time,
        expires: length == null ? null : time.add(length),
        automatic: true,
        offenses: offenses,
      ),
    );
    counter.reset(value);
    print(
      'Banned ${_describe(kind, value)} '
      '${length == null
          ? 'for good'
          : length.inDays == 1
          ? 'for 1 day'
          : 'for ${length.inDays} days'} after '
      '${limits.strikesPerDay} refused requests (last: $reason)',
    );
  }

  /// Removes every correction from the install or IP address [value], for
  /// after banning a spammer. Returns how many were removed.
  ///
  /// The relay may be adding corrections meanwhile, so anything written
  /// while this runs is copied over too.
  int purge(BanKind kind, String value) {
    final field = kind == BanKind.install ? 'installId' : 'ip';
    if (!file.existsSync()) return 0;
    final temp = File('${file.path}.purge');
    final out = temp.openSync(mode: FileMode.write);
    var removed = 0;
    var copied = 0;
    try {
      while (true) {
        final length = file.lengthSync();
        if (length == copied) break;
        final raf = file.openSync()..setPositionSync(copied);
        final bytes = raf.readSync(length - copied);
        raf.closeSync();
        // Only whole lines; a line being written is picked up next time.
        final end = bytes.lastIndexOf(10) + 1;
        if (end == 0) {
          // An unfinished last line: keep it as it is.
          out.writeFromSync(bytes);
          break;
        }
        for (final line in utf8.decode(bytes.sublist(0, end)).split('\n')) {
          if (line.isEmpty) continue;
          if (_fieldOf(line, field) == value) {
            removed++;
          } else {
            out.writeStringSync('$line\n');
          }
        }
        copied += end;
      }
    } finally {
      out.closeSync();
    }
    temp.renameSync(file.path);
    return removed;
  }

  /// Corrections in the log by install ID, with when each was first and
  /// last seen and the IP address it last sent from, most corrections first.
  List<
    ({String installId, int count, String first, String last, String lastIp})
  >
  senders() {
    if (!file.existsSync()) return [];
    final stats = <String, (int, String, String, String)>{};
    for (final line in file.readAsLinesSync()) {
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (json is! Map || json['installId'] is! String) continue;
      final id = json['installId'] as String;
      final at = json['receivedAt'] as String? ?? '';
      // Lines from before IP addresses were logged have none.
      final ip = json['ip'] as String? ?? '';
      final (count, first, _, _) = stats[id] ?? (0, at, at, ip);
      stats[id] = (count + 1, first, at, ip);
    }
    return [
      for (final MapEntry(key: id, value: (count, first, last, ip))
          in stats.entries)
        (installId: id, count: count, first: first, last: last, lastIp: ip),
    ]..sort((a, b) => b.count.compareTo(a.count));
  }

  static String? _fieldOf(String line, String field) {
    try {
      final json = jsonDecode(line);
      return json is Map ? json[field] as String? : null;
    } on FormatException {
      return null;
    }
  }

  /// Checked before the body is read, so refused requests cost almost
  /// nothing. Returns why the request is refused, or null to carry on.
  Refusal? admit(String ip) {
    final time = now();
    if (!_overall.allows('all', time)) return _refuse(Refusal.overall, 'all');
    if (!_perIp.allows(ip, time)) return _refuse(Refusal.ip, ip);
    if (file.existsSync() && file.lengthSync() >= limits.maxLogBytes) {
      return _refuse(Refusal.full, 'full');
    }
    return null;
  }

  /// Checked once the install ID is known. Returns why the correction is
  /// refused, or null if it can be written.
  Refusal? admitInstall(String installId) {
    if (_perInstall.allows(installId, now())) return null;
    return _refuse(Refusal.install, installId);
  }

  /// Counts a request against the overall and IP limits, whether or not it
  /// turns out to be valid, so malformed floods are limited too.
  void countRequest(String ip) {
    final time = now();
    _overall.count('all', time);
    _perIp.count(ip, time);
  }

  void write(Correction correction) {
    _perInstall.count(correction.installId, now());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(correction.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Duration retryAfter(Refusal refusal) => switch (refusal) {
    Refusal.ip => _perIp.retryAfter(now()),
    Refusal.install => _perInstall.retryAfter(now()),
    Refusal.overall || Refusal.full => _overall.retryAfter(now()),
  };

  Refusal _refuse(Refusal refusal, String who) {
    final whom = refusal == Refusal.install
        ? _describe(BanKind.install, who)
        : refusal == Refusal.ip
        ? _describe(BanKind.ip, who)
        : 'everyone';
    _report('${refusal.name}:$who', switch (refusal) {
      Refusal.full =>
        'Corrections refused: corrections.jsonl has reached '
            '${limits.maxLogBytes ~/ 1048576} MB',
      _ => 'Corrections rate limited for $whom',
    });
    return refusal;
  }

  /// Prints [message] at most once an hour for [key].
  void _report(String key, String message) {
    final time = now();
    final since = _reportedSince;
    if (since == null || time.difference(since) >= Duration(hours: 1)) {
      _reported.clear();
      _reportedSince = time;
    }
    // Bounded like the counters: at most one entry per sender seen this hour,
    // and logging stops once there are too many to be useful.
    if (_reported.length < 1000 && _reported.add(key)) print(message);
  }
}

String _describe(BanKind kind, String value) =>
    kind == BanKind.install ? 'install ${_short(value)}' : 'IP $value';

String _short(String id) => id.length > 8 ? '${id.substring(0, 8)}…' : id;

String newCorrectionId() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(12, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}
