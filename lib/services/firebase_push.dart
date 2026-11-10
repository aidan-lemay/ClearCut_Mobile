import 'package:clearcut_mobile/services/alert_notifications.dart';
import 'package:clearcut_mobile/services/notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

/// Push through Firebase Cloud Messaging. Only works in builds that include
/// `android/app/google-services.json`; see the README.
class FirebasePushService implements PushService {
  bool _available = false;

  @override
  bool get available => _available;

  Future<void> init() async {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundMessage);
      _available = true;
    } catch (error) {
      print('Push is unavailable in this build: $error');
    }
  }

  // The classic registration token is kept on purpose: it's what the relay's
  // FCM HTTP v1 send uses as `message.token`. The newer register() flow gives
  // an installation ID for a different send path.
  @override
  Future<String?> getToken() async => _available
      // ignore: deprecated_member_use
      ? FirebaseMessaging.instance.getToken()
      : null;

  @override
  Stream<String> get onTokenRefresh => _available
      // ignore: deprecated_member_use
      ? FirebaseMessaging.instance.onTokenRefresh
      : Stream.empty();

  @override
  Stream<Map<String, String>> get onMessage => _available
      ? FirebaseMessaging.onMessage.map((message) => _strings(message.data))
      : Stream.empty();

  @override
  Future<bool> requestPermission() => requestAlertPermission();
}

Map<String, String> _strings(Map<String, dynamic> data) =>
    data.map((key, value) => MapEntry(key, '$value'));

/// Runs in its own isolate when a push arrives with the app closed or in the
/// background.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundMessage(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  // The relay may not have heard about an unsubscribe or pause yet.
  if (!await alertsAllowedFromStorage()) return;
  await initAlertNotifications();
  // Rules saved before this version of the app have no categories yet.
  try {
    await syncRuleChannels(await rulesFromStorage());
  } catch (error) {
    print('Error updating notification categories: $error');
  }
  await showAlert(_strings(message.data));
}
