import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'bans.dart';
import 'corrections.dart';
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

/// Paths anyone can use, without an access key.
const _publicPaths = {'healthz', 'v1/corrections'};

/// Requires `Authorization: Bearer <key>` on everything except
/// [_publicPaths].
Middleware _authenticate(RelayStore store) =>
    (inner) => (request) {
      if (_publicPaths.contains(request.url.path)) return inner(request);
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

Future<Object?> _readJson(
  Request request, {
  int maxBytes = _maxBodyBytes,
}) async {
  final length = request.contentLength;
  if (length != null && length > maxBytes) {
    throw FormatException('The request is too large.');
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) {
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

/// The address a request came from, for rate limiting.
///
/// Behind a proxy or tunnel every request comes from the proxy, so
/// [clientIpHeader] names the header it puts the real address in, such as
/// `CF-Connecting-IP` for Cloudflare or `X-Real-IP` for nginx. The header is
/// only trusted when configured, since anyone can send it. For
/// `X-Forwarded-For`, the last address is used: the one the proxy saw.
///
/// IPv6 addresses are limited by their /64 network, since one home or phone
/// is usually given a whole /64 and can pick any address in it.
String clientIp(Request request, {String? clientIpHeader}) {
  String? text;
  if (clientIpHeader != null) {
    text = request.headers[clientIpHeader]?.split(',').last.trim();
  }
  if (text == null || text.isEmpty) {
    final info = request.context['shelf.io.connection_info'];
    text = info is HttpConnectionInfo ? info.remoteAddress.address : 'unknown';
  }
  return normalizeIp(text) ?? 'unknown';
}

Response _refused(CorrectionLog log, Refusal refusal) {
  final seconds = log.retryAfter(refusal).inSeconds + 1;
  final response = switch (refusal) {
    Refusal.full => _error(
      503,
      'The relay isn\'t taking corrections right now.',
    ),
    Refusal.overall => _error(
      503,
      'The relay has had too many corrections today. Try again later.',
    ),
    _ => _error(429, 'Too many corrections. Try again later.'),
  };
  return response.change(headers: {'Retry-After': '$seconds'});
}

/// The latest pause end accepted, so a bad value can't overflow a date.
const _maxPausedUntil = 4102444800; // 2100-01-01

/// [maxDevicesPerKey] limits how many phones one key can register, so a
/// leaked key can't be used to open unlimited Clearcut connections.
///
/// [corrections] takes transcript corrections from anyone with the app; see
/// [clientIp] for [clientIpHeader].
Handler buildApi(
  Relay relay, {
  int maxDevicesPerKey = 10,
  CorrectionLog? corrections,
  String? clientIpHeader,
}) {
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
    final systems = rules.map((rule) => rule.systemId).toSet();
    if (systems.length > maxSystemsPerDevice) {
      return _error(
        400,
        'Rules can cover at most $maxSystemsPerDevice '
        'systems.',
      );
    }
    final paused = body['paused'] ?? false;
    final pausedUntilRaw = body['pausedUntil'];
    if (paused is! bool ||
        (pausedUntilRaw != null &&
            (pausedUntilRaw is! int ||
                pausedUntilRaw < 0 ||
                pausedUntilRaw > _maxPausedUntil))) {
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
      final keyId = _keyOf(request).id;
      final count = relay.store.devices.values
          .where((device) => device.keyId == keyId)
          .length;
      if (count >= maxDevicesPerKey) {
        return _error(
          403,
          'This access key already has $maxDevicesPerKey phones registered. '
          'Unsubscribe one of them, or ask for another key.',
        );
      }
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

  // Public, so the cheap limits run before the body is even read. No CORS
  // headers are sent, and a JSON content type is required, so a web page
  // can't make its visitors' browsers send corrections.
  router.post('/v1/corrections', (Request request) async {
    final log = corrections;
    if (log == null) return _error(404, 'Not found.');
    final ip = clientIp(request, clientIpHeader: clientIpHeader);
    final refusal = log.admit(ip);
    if (refusal == Refusal.ip) {
      log.strike(BanKind.ip, ip, 'over the rate limit');
    }
    if (refusal != null) return _refused(log, refusal);
    log.countRequest(ip);

    // Banned senders are answered as if accepted, so a bot doesn't know to
    // switch to a new ID or address.
    Response pretendAccepted() =>
        _json(200, {'ok': true, 'id': newCorrectionId()});
    if (log.isBanned(BanKind.ip, ip)) return pretendAccepted();

    if (request.mimeType != 'application/json') {
      log.strike(BanKind.ip, ip, 'not JSON');
      return _error(415, 'Send corrections as application/json.');
    }
    final Object? body;
    try {
      body = await _readJson(request, maxBytes: maxCorrectionBodyBytes);
    } on FormatException catch (error) {
      log.strike(BanKind.ip, ip, error.message);
      return _error(400, error.message);
    }
    // Known before the rest is checked, so a banned install is dropped
    // without a strike, and a bad correction counts against its install.
    final installId = body is Map ? body['installId'] : null;
    final knownInstall = installId is String && isValidInstallId(installId)
        ? installId
        : null;
    if (knownInstall != null && log.isBanned(BanKind.install, knownInstall)) {
      return pretendAccepted();
    }

    final Correction correction;
    try {
      correction = parseCorrection(
        body,
        id: newCorrectionId(),
        receivedAt: relay.now(),
        ip: ip,
      );
    } on FormatException catch (error) {
      log.strike(BanKind.ip, ip, error.message);
      if (knownInstall != null) {
        log.strike(BanKind.install, knownInstall, error.message);
      }
      return _error(400, error.message);
    }
    final installRefusal = log.admitInstall(correction.installId);
    if (installRefusal != null) {
      log.strike(BanKind.install, correction.installId, 'over the rate limit');
      return _refused(log, installRefusal);
    }

    log.write(correction);
    return _json(200, {'ok': true, 'id': correction.id});
  });

  return Pipeline()
      .addMiddleware(_handleErrors())
      .addMiddleware(_authenticate(relay.store))
      .addHandler(router.call);
}
