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

      final error = FcmError.parse(response.statusCode, response.body);
      if (error.tokenIsDead) {
        print('Firebase rejected a push token: $error');
        return PushResult.invalidToken;
      }
      final retryable =
          response.statusCode == 429 || response.statusCode >= 500;
      if (retryable && attempt < 3) {
        await Future.delayed(Duration(seconds: attempt * 2));
        continue;
      }
      print('Push failed: $error${error.hint}');
      return PushResult.failed;
    }
  }

  @override
  void close() => _client.close();
}

/// An error response from FCM's send API.
class FcmError {
  final int status;

  /// Such as `UNREGISTERED`, `SENDER_ID_MISMATCH` or `INVALID_ARGUMENT`.
  final String code;
  final String message;

  FcmError(this.status, this.code, this.message);

  factory FcmError.parse(int status, String body) {
    var code = '';
    var message = body;
    try {
      final error = (jsonDecode(body) as Map)['error'] as Map;
      message = '${error['message'] ?? ''}';
      code = '${error['status'] ?? ''}';
      for (final detail in error['details'] as List? ?? []) {
        if (detail is Map && detail['errorCode'] is String) {
          code = detail['errorCode'];
        }
      }
    } catch (_) {
      // Not FCM's usual error shape; keep the raw body as the message.
    }
    return FcmError(status, code, message);
  }

  /// Only these mean the phone's token will never work again, so the phone
  /// can be forgotten. Anything else, like a misconfigured Firebase project,
  /// is the relay's problem and mustn't remove phones.
  bool get tokenIsDead =>
      code == 'UNREGISTERED' ||
      (code == 'INVALID_ARGUMENT' &&
          message.toLowerCase().contains('registration token'));

  String get hint => switch (code) {
    'SENDER_ID_MISMATCH' =>
      '. The Firebase key in the relay is from a '
          'different Firebase project than the app\'s google-services.json.',
    'THIRD_PARTY_AUTH_ERROR' || 'PERMISSION_DENIED' =>
      '. Check that the Firebase Cloud Messaging API (V1) is enabled for '
          'the project.',
    _ => '',
  };

  @override
  String toString() => '$status $code: $message';
}
