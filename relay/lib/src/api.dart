import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'push.dart';
import 'relay.dart';
import 'rules.dart';
import 'store.dart';

/// Bumped when the API changes in a way older apps can't handle.
const apiVersion = 1;

const _maxBodyBytes = 512 * 1024;
final _deviceIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

Response _error(int status, String message) =>
    _json(status, {'error': message});

ApiKey _keyOf(Request request) => request.context['key'] as ApiKey;

/// Requires `Authorization: Bearer <key>` on everything except /healthz.
Middleware _authenticate(RelayStore store) =>
    (inner) => (request) {
      if (request.url.path == 'healthz') return inner(request);
      final header = request.headers['authorization'] ?? '';
      final secret = header.startsWith('Bearer ')
          ? header.substring(7).trim()
          : '';
      final key = secret.isEmpty ? null : store.authenticate(secret);
      if (key == null) {
        return _error(401, 'Missing or unknown access key.');
      }
      return inner(request.change(context: {'key': key}));
    };

Middleware _handleErrors() =>
    (inner) => (request) async {
      try {
        return await inner(request);
      } catch (error, stack) {
        print(
          'Error handling ${request.method} /${request.url}: $error\n$stack',
        );
        return _error(500, 'The relay hit an error.');
      }
    };

Future<Object?> _readJson(Request request) async {
  final length = request.contentLength;
  if (length != null && length > _maxBodyBytes) {
    throw FormatException('The request is too large.');
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxBodyBytes) {
      throw FormatException('The request is too large.');
    }
  }
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw FormatException('The request body isn\'t valid JSON.');
  }
}

/// Finds [id] for this key. Returns an error response instead if the ID is
/// malformed or registered under a different key.
(Device?, Response?) _deviceFor(Relay relay, Request request, String id) {
  if (!_deviceIdPattern.hasMatch(id)) {
    return (null, _error(400, 'Invalid device ID.'));
  }
  final device = relay.store.devices[id];
  if (device != null && device.keyId != _keyOf(request).id) {
    return (null, _error(403, 'This device is registered with another key.'));
  }
  return (device, null);
}

Handler buildApi(Relay relay) {
  final router = Router();

  router.get('/healthz', (Request request) => _json(200, {'ok': true}));

  router.get('/v1/status', (Request request) {
    final watched = relay.watchedTalkgroups;
    return _json(200, {
      'ok': true,
      'apiVersion': apiVersion,
      'keyName': _keyOf(request).name,
      'push': relay.push.kind,
      'watchingSystems': watched.length,
      'watchingTalkgroups': watched.values.fold<int>(
        0,
        (sum, tgs) => sum + tgs.length,
      ),
    });
  });

  // The phone sends its whole notification setup each time it changes.
  router.put('/v1/devices/<id>', (Request request, String id) async {
    final (existing, problem) = _deviceFor(relay, request, id);
    if (problem != null) return problem;

    final Object? body;
    try {
      body = await _readJson(request);
    } on FormatException catch (error) {
      return _error(400, error.message);
    }
    if (body is! Map) return _error(400, 'Expected a JSON object.');

    final token = body['token'];
    if (token is! String || token.isEmpty || token.length > 4096) {
      return _error(400, 'A push token is required.');
    }
    final rawRules = body['rules'];
    if (rawRules is! List || rawRules.length > maxRulesPerDevice) {
      return _error(400, 'Send up to $maxRulesPerDevice rules.');
    }
    final List<Rule> rules;
    try {
      rules = [for (final rule in rawRules) Rule.fromJson(rule)];
    } on FormatException catch (error) {
      return _error(400, error.message);
    }
    final paused = body['paused'] ?? false;
    final pausedUntilRaw = body['pausedUntil'];
    if (paused is! bool || (pausedUntilRaw != null && pausedUntilRaw is! int)) {
      return _error(
        400,
        'paused must be true or false, and pausedUntil a '
        'time in seconds or null.',
      );
    }
    final pausedUntil = pausedUntilRaw is int
        ? DateTime.fromMillisecondsSinceEpoch(
            pausedUntilRaw * 1000,
            isUtc: true,
          )
        : null;

    final time = relay.now();
    if (existing != null) {
      existing
        ..token = token
        ..rules = rules
        ..paused = paused
        ..pausedUntil = pausedUntil
        ..updated = time;
    } else {
      relay.store.devices[id] = Device(
        id: id,
        keyId: _keyOf(request).id,
        token: token,
        rules: rules,
        paused: paused,
        pausedUntil: pausedUntil,
        updated: time,
      );
      print('Device $id registered with key "${_keyOf(request).name}"');
    }
    relay.store.scheduleSave();
    relay.refreshStreams();
    return _json(200, {'ok': true});
  });

  router.delete('/v1/devices/<id>', (Request request, String id) {
    final (existing, problem) = _deviceFor(relay, request, id);
    if (problem != null) return problem;
    if (existing != null) {
      relay.store.devices.remove(id);
      relay.store.scheduleSave();
      relay.refreshStreams();
      print('Device $id unsubscribed');
    }
    return _json(200, {'ok': true});
  });

  router.post('/v1/devices/<id>/test', (Request request, String id) async {
    final (device, problem) = _deviceFor(relay, request, id);
    if (problem != null) return problem;
    if (device == null) return _error(404, 'This device isn\'t registered.');
    final result = await relay.sendTo(device, {
      'type': 'test',
      'text': 'Notifications from this relay are working.',
    });
    return switch (result) {
      PushResult.sent => _json(200, {'ok': true, 'push': relay.push.kind}),
      PushResult.invalidToken => _error(
        410,
        'Firebase rejected this phone\'s push token.',
      ),
      PushResult.failed => _error(502, 'Firebase didn\'t accept the push.'),
    };
  });

  return Pipeline()
      .addMiddleware(_handleErrors())
      .addMiddleware(_authenticate(relay.store))
      .addHandler(router.call);
}
