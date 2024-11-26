import 'dart:convert';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';

class SSEService {
  final String systemName;
  final List<dynamic> talkgroupIds;
  late Function(Map<String, dynamic>) _onEvent;

  SSEService({required this.systemName, required this.talkgroupIds});

  void startListening(Function(Map<String, dynamic>) onEvent) {
    _onEvent = onEvent;
    final talkgroupParams = talkgroupIds.join(',');
    final url =
        'https://clearcutradio.app/api/v1/stream?system=$systemName&talkgroup=$talkgroupParams';

    SSEClient.subscribeToSSE(
      url: url,
      header: {'Accept': 'text/event-stream'},
      method: SSERequestType.GET,
    ).listen((SSEModel model) {
      if (model.data != null) {
        final eventData = jsonDecode(model.data!);
        _onEvent(eventData);
      }
    }, onError: (error) {
      print('SSE Error: $error');
    });
  }

  void stopListening() {
    // No explicit close method required, listener automatically disposes.
  }
}
