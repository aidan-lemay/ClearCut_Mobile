import 'dart:convert';

import 'package:clearcut_mobile/services/notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows relay pushes as Android notifications.
final _plugin = FlutterLocalNotificationsPlugin();

/// For tests, and for alerts whose rules have no notification category, such
/// as from an older relay or a rule that was just deleted.
const _otherChannelId = 'alerts';
const _otherChannelName = 'Other alerts';
const _otherChannelDescription =
    'Test notifications, and alerts from rules that no longer exist';

const _rulesGroupId = 'rules';
const _otherGroupId = 'other';
const _rulePrefix = 'rule_';

/// Each alert rule has its own notification category, so Android settings
/// can give each its own sound, vibration and Do Not Disturb behavior.
String ruleChannelId(String ruleId) =>
    '$_rulePrefix${ruleId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';

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

/// Null off Android, and in tests, where the plugin isn't set up.
AndroidFlutterLocalNotificationsPlugin? get _android {
  try {
    return _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
  } catch (error) {
    return null;
  }
}

/// The app's notification categories, or an empty list on Android 7, which
/// has none.
Future<List<AndroidNotificationChannel>> _channels() async {
  try {
    return await _android?.getNotificationChannels() ?? [];
  } catch (error) {
    return [];
  }
}

/// Makes one notification category per rule, renames those whose rule was
/// renamed, and removes those whose rule was deleted. Android keeps the
/// settings the user chose for each category.
Future<void> syncRuleChannels(List<AlertRule> rules) async {
  final android = _android;
  if (android == null) return;

  await android.createNotificationChannelGroup(AndroidNotificationChannelGroup(
    _rulesGroupId,
    'Alert rules',
    description: 'One category per alert rule',
  ));
  await android.createNotificationChannelGroup(
      AndroidNotificationChannelGroup(_otherGroupId, 'Other'));

  final wanted = {for (final rule in rules) ruleChannelId(rule.id): rule};
  for (final channel in await _channels()) {
    if (channel.id.startsWith(_rulePrefix) && !wanted.containsKey(channel.id)) {
      await android.deleteNotificationChannel(channelId: channel.id);
    }
  }
  // Android only uses the importance and sound for a new category. After
  // that, only the name, description and group change.
  for (final MapEntry(key: id, value: rule) in wanted.entries) {
    await android.createNotificationChannel(AndroidNotificationChannel(
      id,
      rule.name,
      description: rule.summary,
      groupId: _rulesGroupId,
      importance: Importance.high,
    ));
  }
  await android.createNotificationChannel(AndroidNotificationChannel(
    _otherChannelId,
    _otherChannelName,
    description: _otherChannelDescription,
    groupId: _otherGroupId,
    importance: Importance.high,
  ));
}

/// Of the categories for the rules a push matched, the one the user made the
/// most urgent: the highest importance, then one that bypasses Do Not
/// Disturb, then the first rule. Null if none of the rules has one.
@visibleForTesting
AndroidNotificationChannel? pickAlertChannel(
    String? ruleIds, List<AndroidNotificationChannel> channels) {
  final byId = {for (final channel in channels) channel.id: channel};
  final candidates = [
    for (final ruleId in (ruleIds ?? '').split(','))
      if (byId[ruleChannelId(ruleId)] case final channel?) channel
  ];
  if (candidates.isEmpty) return null;
  int rank(AndroidNotificationChannel channel) =>
      channel.importance.value * 2 + (channel.bypassDnd ? 1 : 0);
  return candidates
      .reduce((best, next) => rank(next) > rank(best) ? next : best);
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
  // A call and its later transcript share an ID, so the transcript replaces
  // the "New call" notification instead of adding another.
  final id = stableNotificationId(data['notificationId'] ?? data['type'] ?? '');

  final channel = data['type'] == 'test'
      ? null
      : pickAlertChannel(data['ruleIds'], await _channels());
  final channelId = channel?.id ?? _otherChannelId;

  // A transcript can match a rule the call didn't, such as a keyword. If that
  // moves the notification to another category, post it fresh so it makes
  // that category's sound instead of updating silently.
  try {
    final active = await _android?.getActiveNotifications() ?? [];
    if (active.any((n) => n.id == id && n.channelId != channelId)) {
      await _plugin.cancel(id: id);
    }
  } catch (error) {
    // Updating in place still shows the transcript.
  }

  await _plugin.show(
    id: id,
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
        channelId,
        channel?.name ?? _otherChannelName,
        channelDescription: channel?.description ?? _otherChannelDescription,
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
