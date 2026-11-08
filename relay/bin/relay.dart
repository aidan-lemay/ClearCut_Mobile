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
        ..addCommand(_DevicesCommand());
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
    final server = await shelf_io.serve(
      buildApi(relay, maxDevicesPerKey: maxDevices),
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
