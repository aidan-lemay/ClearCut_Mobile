import 'dart:async';
import 'dart:convert';

import 'package:clearcut_mobile/services/notifications.dart' show newId;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Where corrections are sent: a relay's public corrections endpoint, which
/// needs no access key. Empty keeps corrections on the phone until it's set.
const correctionsUrl = 'https://relay.k5doc.tech/v1/corrections';

const _sendTimeout = Duration(seconds: 15);

/// A user's fix for a call's transcript, sent to the relay for retraining
/// transcription. Kept on the phone until the relay has it.
class TranscriptCorrection {
  final String callId;
  final String systemId;
  final int? talkgroupId;
  final String audioFile;

  /// The transcript as Clearcut had it, which may be empty.
  final String original;
  final String corrected;
  final DateTime createdAt;

  TranscriptCorrection({
    required this.callId,
    required this.systemId,
    required this.talkgroupId,
    required this.audioFile,
    required this.original,
    required this.corrected,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'callId': callId,
        'systemId': systemId,
        'talkgroupId': talkgroupId,
        'audioFile': audioFile,
        'original': original,
        'corrected': corrected,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Returns null if [json] is damaged.
  static TranscriptCorrection? fromJson(Object? json) {
    if (json is! Map ||
        json['callId'] is! String ||
        json['systemId'] is! String ||
        json['corrected'] is! String) {
      return null;
    }
    final talkgroupId = json['talkgroupId'];
    final audioFile = json['audioFile'];
    final original = json['original'];
    final createdAt = json['createdAt'];
    return TranscriptCorrection(
      callId: json['callId'],
      systemId: json['systemId'],
      talkgroupId: talkgroupId is int ? talkgroupId : null,
      audioFile: audioFile is String ? audioFile : '',
      original: original is String ? original : '',
      corrected: json['corrected'],
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
    );
  }
}

/// Corrections waiting to be sent, oldest first, kept across restarts.
class TranscriptCorrections {
  static const _prefsKey = 'pendingTranscriptCorrections';

  static Future<List<TranscriptCorrection>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? [];
    return [
      for (final text in stored)
        if (_decode(text) case final correction?) correction
    ];
  }

  /// Saves [correction], replacing an earlier one for the same call, so a
  /// second fix to a call doesn't leave two answers for it.
  static Future<void> add(TranscriptCorrection correction) async {
    final kept = [
      for (final other in await pending())
        if (other.callId != correction.callId) other
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, [
      for (final c in [...kept, correction]) jsonEncode(c.toJson())
    ]);
  }

  /// Saves [correction] and tries to send everything waiting, this one
  /// included.
  static Future<SendOutcome> submit(TranscriptCorrection correction) async {
    await add(correction);
    final results = await sendPending();
    return results[_identity(correction)] ?? SendOutcome.queued();
  }

  static Future<Map<String, SendOutcome>>? _sending;

  /// Sends waiting corrections, oldest first, stopping at the first that
  /// can't go now (offline, or the relay is limiting requests); the rest wait
  /// for the next try. Corrections the relay refuses outright are dropped,
  /// since they'd never be accepted. Returns what happened to each one tried.
  ///
  /// Only one send runs at a time, so a correction isn't sent twice.
  static Future<Map<String, SendOutcome>> sendPending() {
    return _sending ??= _sendPending().whenComplete(() => _sending = null);
  }

  /// Where corrections go. Only changed by tests.
  static String url = correctionsUrl;

  static Future<Map<String, SendOutcome>> _sendPending() async {
    final results = <String, SendOutcome>{};
    if (url.isEmpty) return results;
    final installId = await _installId();
    for (final correction in await pending()) {
      final outcome = await _send(correction, installId);
      results[_identity(correction)] = outcome;
      if (outcome.isQueued) break;
      await _remove(correction);
    }
    return results;
  }

  static Future<SendOutcome> _send(
      TranscriptCorrection correction, String installId) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'installId': installId,
              'callId': correction.callId,
              'systemId': correction.systemId,
              'talkgroupId': correction.talkgroupId,
              if (correction.audioFile.startsWith('audio/'))
                'audioFile': correction.audioFile,
              'originalTranscript': correction.original,
              'correctedTranscript': correction.corrected,
              'submittedAt': correction.createdAt.toIso8601String(),
            }),
          )
          .timeout(_sendTimeout);
    } catch (error) {
      print('Error sending correction: $error');
      return SendOutcome.queued();
    }
    if (response.statusCode == 200) return SendOutcome.sent();
    if (response.statusCode == 400 || response.statusCode == 415) {
      final reason = _errorOf(response.body) ?? 'The relay refused it.';
      print('Correction for ${correction.callId} refused: $reason');
      return SendOutcome.rejected(reason);
    }
    // Rate limited, full, or down: worth trying again later.
    print('Correction not sent yet: relay returned ${response.statusCode}');
    return SendOutcome.queued();
  }

  static String? _errorOf(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map && json['error'] is String ? json['error'] : null;
    } on FormatException {
      return null;
    }
  }

  static String _identity(TranscriptCorrection c) =>
      '${c.callId}\n${c.corrected}';

  /// Removes [sent], re-reading first in case a correction was added while
  /// it was sending.
  static Future<void> _remove(TranscriptCorrection sent) async {
    final kept = [
      for (final other in await pending())
        if (_identity(other) != _identity(sent)) other
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, [for (final c in kept) jsonEncode(c.toJson())]);
  }

  /// A random ID for this install, sent with corrections so the relay can
  /// tell senders apart and limit each one. It's separate from the
  /// notification device ID, so corrections can't be tied to an access key.
  static Future<String> _installId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_installIdKey) ?? '';
    if (id.isEmpty) {
      id = newId('i');
      await prefs.setString(_installIdKey, id);
    }
    return id;
  }

  static const _installIdKey = 'correctionsInstallId';

  static TranscriptCorrection? _decode(String text) {
    try {
      return TranscriptCorrection.fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }
}

/// What happened to a correction when it was submitted.
class SendOutcome {
  final bool isSent;
  final bool isQueued;

  /// Why the relay refused it, written for the user.
  final String? rejection;

  SendOutcome.sent()
      : isSent = true,
        isQueued = false,
        rejection = null;
  SendOutcome.queued()
      : isSent = false,
        isQueued = true,
        rejection = null;
  SendOutcome.rejected(String this.rejection)
      : isSent = false,
        isQueued = false;
}
