import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:clearcut_relay/relay.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Directory get _dataDir =>
    Directory(Platform.environment['RELAY_DATA_DIR'] ?? 'data');

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<void>('relay', 'Push notifications for Clearcut Mobile.')
        ..addCommand(_ServeCommand())
        ..addCommand(_KeysCommand())
        ..addCommand(_DevicesCommand())
        ..addCommand(_CorrectionsCommand());
  try {
    await runner.run(args);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

class _ServeCommand extends Command<void> {
  @override
  final name = 'serve';
  @override
  final description = 'Run the relay.';

  @override
  Future<void> run() async {
    final env = Platform.environment;
    final port = int.tryParse(env['RELAY_PORT'] ?? '') ?? 8080;
    final store = RelayStore(_dataDir)
      ..reloadKeys()
      ..loadDevices()
      ..removeOrphanedDevices();

    final credentials = File(
      env['FCM_CREDENTIALS'] ??
          '${_dataDir.path}/firebase-service-account.json',
    );
    final PushSender push;
    if (credentials.existsSync()) {
      push = await FcmPushSender.fromFile(credentials);
      print(
        'Sending pushes with Firebase project '
        '${(push as FcmPushSender).projectId}',
      );
    } else {
      push = LogPushSender();
      print(
        'No Firebase key at ${credentials.path}, so pushes are only '
        'logged, not sent.',
      );
    }

    final relay = Relay(store, push)..start();
    final maxDevices =
        int.tryParse(env['RELAY_MAX_DEVICES_PER_KEY'] ?? '') ?? 10;
    final corrections = env['RELAY_CORRECTIONS'] == 'off'
        ? null
        : CorrectionLog(
            _dataDir,
            limits: CorrectionLimits.fromEnvironment(env),
          );
    final ipHeader = env['RELAY_CLIENT_IP_HEADER']?.trim().toLowerCase();
    if (corrections != null) {
      final limits = corrections.limits;
      print(
        'Taking transcript corrections into ${corrections.file.path}: up to '
        '${limits.perIpPerHour} an hour per IP, '
        '${limits.perInstallPerDay} a day per install, '
        '${limits.totalPerDay} a day in all',
      );
      if (ipHeader == null || ipHeader.isEmpty) {
        print(
          'RELAY_CLIENT_IP_HEADER isn\'t set, so corrections are limited by '
          'the connecting address. Behind a proxy or tunnel, set it so each '
          'sender is limited separately.',
        );
      }
    }
    final server = await shelf_io.serve(
      buildApi(
        relay,
        maxDevicesPerKey: maxDevices,
        corrections: corrections,
        clientIpHeader: ipHeader == null || ipHeader.isEmpty ? null : ipHeader,
      ),
      InternetAddress.anyIPv4,
      port,
      // Don't advertise what the server runs.
      poweredByHeader: null,
    );
    print(
      'Relay listening on port ${server.port} with ${store.keys.length} '
      'keys and ${store.devices.length} devices',
    );
    if (store.keys.isEmpty) {
      print('No access keys yet. Make one with: relay keys create <name>');
    }

    final done = Completer<void>();
    Future<void> shutDown(ProcessSignal signal) async {
      if (done.isCompleted) return;
      print('Shutting down');
      relay.stop();
      await server.close(force: true);
      store.saveDevicesNow();
      push.close();
      done.complete();
    }

    ProcessSignal.sigint.watch().listen(shutDown);
    ProcessSignal.sigterm.watch().listen(shutDown);
    await done.future;
    exit(0);
  }
}

class _KeysCommand extends Command<void> {
  @override
  final name = 'keys';
  @override
  final description =
      'Manage access keys. Changes apply to a running relay '
      'within 15 seconds.';

  _KeysCommand() {
    addSubcommand(_KeysCreateCommand());
    addSubcommand(_KeysListCommand());
    addSubcommand(_KeysRevokeCommand());
  }
}

String _nameArgument(Command command) {
  final rest = command.argResults!.rest;
  if (rest.length != 1 || rest.single.trim().isEmpty) {
    command.usageException('Give one key name, such as a person\'s name.');
  }
  return rest.single.trim();
}

class _KeysCreateCommand extends Command<void> {
  @override
  final name = 'create';
  @override
  final description = 'Make a key for one person. The key is shown once.';
  @override
  String get invocation => 'relay keys create <name>';

  @override
  void run() {
    final (key, secret) = RelayStore(_dataDir).createKey(_nameArgument(this));
    print(
      'Made key "${key.name}". Enter it in the app under Settings > '
      'Notifications:\n\n  $secret\n\n'
      'It isn\'t stored anywhere, so copy it now. If it\'s lost, revoke it '
      'and make another.',
    );
  }
}

class _KeysListCommand extends Command<void> {
  @override
  final name = 'list';
  @override
  final description = 'List keys and how many phones use each.';

  @override
  void run() {
    final store = RelayStore(_dataDir)
      ..reloadKeys()
      ..loadDevices();
    if (store.keys.isEmpty) {
      print('No keys. Make one with: relay keys create <name>');
      return;
    }
    for (final key in store.keys) {
      final phones = store.devices.values
          .where((device) => device.keyId == key.id)
          .length;
      print(
        '${key.name.padRight(24)} created '
        '${key.created.toLocal().toString().substring(0, 16)}, '
        '$phones ${phones == 1 ? 'phone' : 'phones'}',
      );
    }
  }
}

class _KeysRevokeCommand extends Command<void> {
  @override
  final name = 'revoke';
  @override
  final description =
      'Delete a key. Phones using it stop getting '
      'notifications.';
  @override
  String get invocation => 'relay keys revoke <name>';

  @override
  void run() {
    final name = _nameArgument(this);
    if (!RelayStore(_dataDir).revokeKey(name)) {
      throw StateError('No key named "$name".');
    }
    print('Revoked "$name".');
  }
}

class _DevicesCommand extends Command<void> {
  @override
  final name = 'devices';
  @override
  final description = 'List registered phones and their rules.';

  @override
  void run() {
    final store = RelayStore(_dataDir)
      ..reloadKeys()
      ..loadDevices();
    if (store.devices.isEmpty) {
      print('No phones registered.');
      return;
    }
    final names = {for (final key in store.keys) key.id: key.name};
    final now = DateTime.now();
    for (final device in store.devices.values) {
      final state = device.isActive(now)
          ? 'active'
          : device.pausedUntil == null
          ? 'paused'
          : 'paused until ${device.pausedUntil!.toLocal()}';
      print(
        '${device.id} (key "${names[device.keyId] ?? '?'}"), $state, '
        'last push ${device.lastPush?.toLocal() ?? 'never'}',
      );
      for (final rule in device.rules) {
        print(
          '  ${rule.enabled ? '-' : 'x'} ${rule.name}: ${rule.mode.name} '
          'on ${rule.systemId}, ${rule.talkgroups.length} talkgroups'
          '${rule.keywords.isEmpty ? '' : ', keywords ${rule.keywords.join(', ')}'}',
        );
      }
    }
  }
}

class _CorrectionsCommand extends Command<void> {
  @override
  final name = 'corrections';
  @override
  final description =
      'See who sends transcript corrections, and ban spammers. Bans apply to '
      'a running relay at once.';

  _CorrectionsCommand() {
    addSubcommand(_SendersCommand());
    addSubcommand(_BansCommand());
    addSubcommand(_BanCommand());
    addSubcommand(_UnbanCommand());
  }
}

CorrectionLog get _correctionLog => CorrectionLog(_dataDir);

(BanKind, String) _banTarget(Command command) {
  final rest = command.argResults!.rest;
  if (rest.length != 1) {
    command.usageException('Give one install ID or IP address.');
  }
  try {
    return parseBanTarget(rest.single);
  } on FormatException catch (error) {
    command.usageException(error.message);
  }
}

/// A stored time, as `relay corrections` shows them.
String _stamp(String iso) {
  final time = DateTime.tryParse(iso);
  return time == null ? iso : _when(time);
}

String _when(DateTime time) =>
    time.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ');

class _SendersCommand extends Command<void> {
  @override
  final name = 'senders';
  @override
  final description =
      'List installs by how many corrections they have sent, most first.';

  _SendersCommand() {
    argParser.addOption('top', defaultsTo: '20', help: 'How many to show.');
  }

  @override
  void run() {
    final top = int.tryParse(argResults!['top']) ?? 20;
    final log = _correctionLog;
    final senders = log.senders();
    if (senders.isEmpty) {
      print('No corrections yet.');
      return;
    }
    final total = senders.fold<int>(0, (sum, s) => sum + s.count);
    String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    print(
      '${count(total, 'correction')} from '
      '${count(senders.length, 'install')}. Times are UTC.\n',
    );
    for (final sender in senders.take(top)) {
      final banned = log.bans.active(
        BanKind.install,
        sender.installId,
        DateTime.now(),
      );
      print(
        '${sender.installId.padRight(28)} ${'${sender.count}'.padLeft(6)}  '
        'first ${_stamp(sender.first)}  last ${_stamp(sender.last)}  '
        '${sender.lastIp.isEmpty ? '' : 'from ${sender.lastIp}'}'
        '${banned == null ? '' : '  BANNED'}',
      );
    }
  }
}

class _BansCommand extends Command<void> {
  @override
  final name = 'bans';
  @override
  final description = 'List bans, including automatic ones.';

  @override
  void run() {
    final bans = _correctionLog.bans..reload();
    if (bans.bans.isEmpty) {
      print('No bans.');
      return;
    }
    final now = DateTime.now();
    for (final ban in bans.bans) {
      final state = !ban.isActive(now)
          ? 'expired ${_when(ban.expires!)}'
          : ban.expires == null
          ? 'for good'
          : 'until ${_when(ban.expires!)}';
      print(
        '${ban.kind.name.padRight(8)} ${ban.value.padRight(28)} $state, '
        '${ban.automatic ? 'automatic (offense ${ban.offenses})' : 'manual'}'
        '${ban.reason.isEmpty ? '' : ': ${ban.reason}'}',
      );
    }
    print('\nTimes are UTC.');
  }
}

class _BanCommand extends Command<void> {
  @override
  final name = 'ban';
  @override
  final description =
      'Ban an install ID or IP address from sending corrections. They '
      'aren\'t told, so a bot keeps using the banned ID.';
  @override
  String get invocation => 'relay corrections ban <install ID or IP>';

  _BanCommand() {
    argParser
      ..addOption('reason', help: 'A note for yourself, shown in the list.')
      ..addOption('days', help: 'End the ban after this many days.')
      ..addFlag(
        'purge',
        negatable: false,
        help:
            'Also delete the corrections this install or IP address '
            'already sent.',
      );
  }

  @override
  void run() {
    final (kind, value) = _banTarget(this);
    final daysText = argResults!['days'] as String?;
    final days = daysText == null ? null : int.tryParse(daysText);
    if (daysText != null && (days == null || days < 1)) {
      usageException('--days must be a whole number of days.');
    }
    final purge = argResults!['purge'] as bool;
    final log = _correctionLog;
    final now = DateTime.now();
    log.bans.add(
      Ban(
        kind: kind,
        value: value,
        reason: argResults!['reason'] ?? '',
        created: now,
        expires: days == null ? null : now.add(Duration(days: days)),
      ),
    );
    print(
      'Banned ${kind.name} $value '
      '${days == null ? 'for good' : 'for $days days'}.',
    );
    if (purge) {
      final removed = log.purge(kind, value);
      print('Removed $removed of its corrections from ${log.file.path}.');
    }
  }
}

class _UnbanCommand extends Command<void> {
  @override
  final name = 'unban';
  @override
  final description =
      'Lift a ban, and forget its history, so a later automatic ban starts '
      'short again.';
  @override
  String get invocation => 'relay corrections unban <install ID or IP>';

  @override
  void run() {
    final (kind, value) = _banTarget(this);
    if (!_correctionLog.bans.remove(kind, value)) {
      throw StateError('No ban on ${kind.name} $value.');
    }
    print('Unbanned ${kind.name} $value.');
  }
}
