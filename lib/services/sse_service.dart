import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Decodes a stream of raw SSE lines into JSON objects.
///
/// Comments, keepalive frames, and anything that isn't a JSON object are
/// skipped, so a malformed event can't take down the stream.
Stream<Map<String, dynamic>> parseSseEvents(Stream<String> lines) {
  final data = StringBuffer();

  return lines.transform(
    StreamTransformer.fromHandlers(handleData: (line, sink) {
      if (line.isEmpty) {
        if (data.isEmpty) return;
        final payload = data.toString();
        data.clear();
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) sink.add(decoded);
        } on FormatException catch (error) {
          print('Skipping malformed SSE event: $error');
        }
      } else if (line.startsWith('data:')) {
        var value = line.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        if (data.isNotEmpty) data.write('\n');
        data.write(value);
      }
    }),
  );
}

/// Holds a live connection to the call stream, reconnecting whenever it drops
/// (server close, network change, phone sleep) until [stop] is called.
class SSEService {
  static const _connectTimeout = Duration(seconds: 15);
  static const _maxRetryDelay = Duration(seconds: 30);
  static const _stableConnection = Duration(seconds: 30);


  final String systemName;
  final List<dynamic> talkgroupIds;
  final void Function(Map<String, dynamic> event) onEvent;

  /// Called when a connection comes up after an earlier one dropped or failed.
  /// Events sent while disconnected are lost, so callers should re-fetch here.
  final void Function()? onReconnected;

  /// How long a stream can go without data before it's treated as dead. The
  /// server resets a stream after roughly two minutes without data, so going
  /// longer than that means the socket has silently died.
  final Duration idleTimeout;

  SSEService({
    required this.systemName,
    required this.talkgroupIds,
    required this.onEvent,
    this.onReconnected,
    this.idleTimeout = const Duration(seconds: 150),
  });

  http.Client? _client;
  Timer? _retryTimer;
  void Function()? _abortStream;
  bool _running = false;
  bool _attemptedBefore = false;
  int _failures = 0;

  // Bumped for each connection, so one that has been replaced or stopped can
  // tell that it should no longer deliver events or schedule a retry.
  int _generation = 0;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  void stop() {
    _running = false;
    _closeConnection();
  }

  /// Drops the current connection and opens a new one right away. Use after
  /// the app resumes, when a socket may be dead without having reported it.
  void reconnectNow() {
    if (!_running) return;
    _closeConnection();
    _failures = 0;
    _connect();
  }

  void _closeConnection() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _abortStream?.call();
    _abortStream = null;
    _client?.close();
    _client = null;
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final client = http.Client();
    _client = client;

    final isRetry = _attemptedBefore;
    _attemptedBefore = true;

    final talkgroups = talkgroupIds.join(',');
    final request = http.Request(
      'GET',
      Uri.parse(
          'https://clearcutradio.app/api/v1/stream?system=$systemName&talkgroup=$talkgroups'),
    )..headers['Accept'] = 'text/event-stream';

    DateTime? connectedAt;
    try {
      final response = await client.send(request).timeout(_connectTimeout);
      if (response.statusCode != 200) {
        throw http.ClientException('Stream returned ${response.statusCode}');
      }
      if (generation != _generation) return;

      connectedAt = DateTime.now();
      if (isRetry) onReconnected?.call();

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(LineSplitter())
          .timeout(idleTimeout);

      final finished = Completer<void>();
      final subscription = parseSseEvents(lines).listen(
        onEvent,
        onError: finished.completeError,
        onDone: finished.complete,
        cancelOnError: true,
      );
      _abortStream = () {
        subscription.cancel();
        if (!finished.isCompleted) finished.complete();
      };
      await finished.future;
    } catch (error) {
      if (generation == _generation) print('SSE error: $error');
    } finally {
      client.close();
    }

    if (generation != _generation) return;

    // Only back off when connections aren't lasting; the server closing a
    // healthy stream shouldn't slow down the reconnect.
    final lasted = connectedAt != null &&
        DateTime.now().difference(connectedAt) >= _stableConnection;
    _failures = lasted ? 0 : _failures + 1;

    final seconds = _failures == 0 ? 1 : 1 << (_failures - 1).clamp(0, 5);
    final delay = Duration(seconds: seconds);
    _retryTimer = Timer(delay > _maxRetryDelay ? _maxRetryDelay : delay, () {
      if (generation == _generation) _connect();
    });
  }
}
