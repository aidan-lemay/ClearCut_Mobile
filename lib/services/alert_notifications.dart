import 'dart:convert';

import 'package:clearcut_mobile/services/notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows relay pushes as Android notifications.
final _plugin = FlutterLocalNotificationsPlugin();

const _channelId = 'alerts';

/// Where a tapped notification leads: a talkgroup and the call to highlight.
class AlertTarget {
  final String systemId;
  final int talkgroupId;
  final String talkgroupName;
  final String? callId;

  AlertTarget({
    required this.systemId,
    required this.talkgroupId,
    required this.talkgroupName,
    this.callId,
  });

  static AlertTarget? fromPayload(String? payload) {
    if (payload == null) return null;
    try {
      final json = jsonDecode(payload);
      final talkgroupId = int.tryParse('${json['talkgroupId']}');
      if (json['systemId'] is! String || talkgroupId == null) return null;
      return AlertTarget(
        systemId: json['systemId'],
        talkgroupId: talkgroupId,
        talkgroupName: json['talkgroupName'] as String? ?? 'Talkgroup',
        callId: json['callId'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

Future<void> initAlertNotifications(
    {void Function(AlertTarget target)? onTap}) async {
  await _plugin.initialize(
    settings: InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_alert'),
    ),
    onDidReceiveNotificationResponse: (response) {
      final target = AlertTarget.fromPayload(response.payload);
      if (target != null) onTap?.call(target);
    },
  );
}

/// The notification the app was opened from, if any.
Future<AlertTarget?> launchAlertTarget() async {
  final details = await _plugin.getNotificationAppLaunchDetails();
  if (details?.didNotificationLaunchApp != true) return null;
  return AlertTarget.fromPayload(details!.notificationResponse?.payload);
}

Future<bool> requestAlertPermission() async {
  final android = _plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  return await android?.requestNotificationsPermission() ?? false;
}

/// The title, text, and summary line for a push from the relay.
({String title, String body, String? summary}) describeAlert(
    Map<String, String> data) {
  if (data['type'] == 'test') {
    return (
      title: 'Clearcut Mobile',
      body: data['text'] ?? 'Test notification',
      summary: null,
    );
  }
  final text = data['text'] ?? '';
  final keywords = data['keywords'] ?? '';
  return (
    title: data['talkgroupName'] ?? 'Clearcut',
    body: text.isEmpty ? 'New call' : text,
    summary: keywords.isNotEmpty ? 'Matched: $keywords' : data['rules'],
  );
}

Future<void> showAlert(Map<String, String> data) async {
  final (:title, :body, :summary) = describeAlert(data);
  final startTime = int.tryParse(data['startTime'] ?? '');

  await _plugin.show(
    // A call and its later transcript share an ID, so the transcript
    // replaces the "New call" notification instead of adding another.
    id: stableNotificationId(data['notificationId'] ?? data['type'] ?? ''),
    title: title,
    body: body,
    payload: data['type'] == 'test'
        ? null
        : jsonEncode({
            'systemId': data['systemId'],
            'talkgroupId': data['talkgroupId'],
            'talkgroupName': data['talkgroupName'],
            'callId': data['callId'],
          }),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Alerts',
        channelDescription: 'Calls and transcripts matching your alert rules',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        styleInformation: BigTextStyleInformation(body, summaryText: summary),
        subText: summary,
        // The transcript update shouldn't make a second sound.
        onlyAlertOnce: true,
        when: startTime == null ? null : startTime * 1000,
        showWhen: true,
      ),
    ),
  );
}
