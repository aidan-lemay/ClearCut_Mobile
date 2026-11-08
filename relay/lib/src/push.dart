import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

enum PushResult {
  sent,

  /// The phone uninstalled the app or its token expired. Stop sending to it.
  invalidToken,
  failed,
}

abstract class PushSender {
  /// Shown in the status the app reads, so a user can tell pushes aren't
  /// really being sent.
  String get kind;

  /// [data] values must all be strings, as FCM requires.
  Future<PushResult> send(String token, Map<String, String> data);

  void close() {}
}

/// Logs pushes instead of sending them, for when no Firebase key is set up.
class LogPushSender extends PushSender {
  @override
  String get kind => 'log';

  @override
  Future<PushResult> send(String token, Map<String, String> data) async {
    final preview = token.length > 12 ? token.substring(0, 12) : token;
    print(
      'Push (not sent, no Firebase key) to $preview...: ${jsonEncode(data)}',
    );
    return PushResult.sent;
  }
}

/// Sends pushes with Firebase Cloud Messaging's HTTP v1 API, using a service
/// account key downloaded from the Firebase console.
class FcmPushSender extends PushSender {
  final String projectId;
  final http.Client _client;

  FcmPushSender._(this.projectId, this._client);

  static Future<FcmPushSender> fromFile(File file) async {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final projectId = json['project_id'];
    if (projectId is! String) {
      throw FormatException(
        '${file.path} has no project_id. Is it a Firebase '
        'service account key?',
      );
    }
    final client = await clientViaServiceAccount(
      ServiceAccountCredentials.fromJson(json),
      ['https://www.googleapis.com/auth/firebase.messaging'],
    );
    return FcmPushSender._(projectId, client);
  }

  @override
  String get kind => 'fcm';

  @override
  Future<PushResult> send(String token, Map<String, String> data) async {
    final body = jsonEncode({
      'message': {
        'token': token,
        'data': data,
        // High priority wakes a sleeping phone right away. The app always
        // shows a notification for it, which Android requires to keep
        // delivering high-priority messages promptly.
        'android': {'priority': 'high', 'ttl': '3600s'},
      },
    });
    final url = Uri.parse(
      'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
    );

    for (var attempt = 1; ; attempt++) {
      http.Response response;
      try {
        response = await _client
            .post(
              url,
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(Duration(seconds: 15));
      } catch (error) {
        if (attempt < 3) {
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }
        print('Push failed: $error');
        return PushResult.failed;
      }

      if (response.statusCode == 200) return PushResult.sent;
      if (response.statusCode == 404 ||
          response.body.contains('UNREGISTERED') ||
          response.body.contains('registration token is not a valid')) {
        return PushResult.invalidToken;
      }
      final retryable =
          response.statusCode == 429 || response.statusCode >= 500;
      if (retryable && attempt < 3) {
        await Future.delayed(Duration(seconds: attempt * 2));
        continue;
      }
      print('Push failed with ${response.statusCode}: ${response.body}');
      return PushResult.failed;
    }
  }

  @override
  void close() => _client.close();
}
