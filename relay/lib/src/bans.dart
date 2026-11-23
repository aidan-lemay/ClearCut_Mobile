import 'dart:convert';
import 'dart:io';

/// Who a ban applies to: one install of the app, or an IP address (an IPv6
/// address's whole /64).
enum BanKind { install, ip }

/// A ban on sending corrections. Banned senders aren't told: their requests
/// look accepted but aren't logged, so a bot doesn't know to switch to a new
/// ID.
class Ban {
  final BanKind kind;
  final String value;
  final String reason;
  final DateTime created;

  /// Null for a ban that never ends.
  final DateTime? expires;

  /// Made by the strike policy rather than by hand.
  final bool automatic;

  /// How many automatic bans this sender has had, counting this one, so
  /// repeat offenders get longer bans. Kept after a ban expires.
  final int offenses;

  Ban({
    required this.kind,
    required this.value,
    required this.reason,
    required this.created,
    this.expires,
    this.automatic = false,
    this.offenses = 0,
  });

  bool isActive(DateTime now) => expires == null || now.isBefore(expires!);

  factory Ban.fromJson(Map<String, dynamic> json) => Ban(
    kind: BanKind.values.byName(json['kind']),
    value: json['value'],
    reason: json['reason'] ?? '',
    created: DateTime.parse(json['created']),
    expires: json['expires'] == null ? null : DateTime.parse(json['expires']),
    automatic: json['automatic'] == true,
    offenses: json['offenses'] ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'value': value,
    'reason': reason,
    'created': created.toUtc().toIso8601String(),
    'expires': expires?.toUtc().toIso8601String(),
    'automatic': automatic,
    'offenses': offenses,
  };
}

final _installIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// The form IP addresses are limited and banned by: IPv4 as is, and IPv6 as
/// its /64 network, since one home or phone is usually given a whole /64 and
/// can pick any address in it. Returns null if [text] isn't an address.
String? normalizeIp(String text) {
  final address = InternetAddress.tryParse(
    text.endsWith('/64') ? text.substring(0, text.length - 3) : text,
  );
  if (address == null) return null;
  if (address.type != InternetAddressType.IPv6) return address.address;
  final network = address.rawAddress.sublist(0, 8);
  final groups = [
    for (var i = 0; i < 8; i += 2)
      ((network[i] << 8) | network[i + 1]).toRadixString(16),
  ];
  return '${groups.join(':')}::/64';
}

/// Reads what was typed after `relay corrections ban`: an install ID or an IP
/// address. Throws [FormatException] if it's neither.
(BanKind, String) parseBanTarget(String text) {
  final ip = normalizeIp(text.trim());
  if (ip != null) return (BanKind.ip, ip);
  if (_installIdPattern.hasMatch(text.trim())) {
    return (BanKind.install, text.trim());
  }
  throw FormatException(
    '"$text" isn\'t an install ID or an IP address. Install IDs are in '
    'corrections.jsonl; see: relay corrections senders',
  );
}

/// The bans in `bans.json`. Both the command-line tool and the running
/// relay change it, so it's re-read whenever it changes on disk, and before
/// every change, so neither overwrites the other's bans.
class BanList {
  final File file;
  var bans = <Ban>[];
  // When bans.json was last read, by modification time and size: times are
  // only to the millisecond, so two quick changes can share one, but adding
  // or removing a ban always changes the size.
  (DateTime, int)? _version;

  BanList(Directory dir) : file = File('${dir.path}/bans.json');

  (DateTime, int) _currentVersion() =>
      (file.lastModifiedSync(), file.lengthSync());

  void reload() {
    if (!file.existsSync()) {
      bans = [];
      _version = null;
      return;
    }
    final version = _currentVersion();
    if (version == _version) return;
    final stored = jsonDecode(file.readAsStringSync()) as List;
    bans = [for (final ban in stored) Ban.fromJson(ban)];
    _version = version;
  }

  /// Any ban, active or expired, kept for escalation.
  Ban? find(BanKind kind, String value) {
    reload();
    for (final ban in bans) {
      if (ban.kind == kind && ban.value == value) return ban;
    }
    return null;
  }

  Ban? active(BanKind kind, String value, DateTime now) {
    final ban = find(kind, value);
    return ban != null && ban.isActive(now) ? ban : null;
  }

  /// Adds [ban], replacing any earlier ban on the same sender.
  void add(Ban ban) {
    reload();
    bans = [
      for (final other in bans)
        if (other.kind != ban.kind || other.value != ban.value) other,
      ban,
    ];
    _save();
  }

  /// Removes the ban and its history. Returns false if there wasn't one.
  bool remove(BanKind kind, String value) {
    reload();
    final before = bans.length;
    bans.removeWhere((ban) => ban.kind == kind && ban.value == value);
    if (bans.length == before) return false;
    _save();
    return true;
  }

  void _save() {
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      JsonEncoder.withIndent(
        '  ',
      ).convert([for (final ban in bans) ban.toJson()]),
    );
    temp.renameSync(file.path);
    _version = _currentVersion();
  }
}
