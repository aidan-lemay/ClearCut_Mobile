/// Helpers for the call data returned by the API and the live stream.
library;

/// System IDs go straight into API URLs, so only plain characters are
/// allowed. The relay applies the same rule.
bool isValidSystemId(String id) =>
    RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(id);

const _audioBaseUrl = 'https://audio.clearcutradio.app/';

/// Returns a copy of [call] with `transcript` flattened to plain text.
///
/// The API sends a transcript as an object, or null if there isn't one.
Map<String, dynamic> normalizeCall(Map<String, dynamic> call) {
  final transcript = call['transcript'];
  final text = transcript is Map ? transcript['text'] : transcript;
  return {...call, 'transcript': text is String ? text : ''};
}

/// Merges [incoming] calls into [existing], newest first.
///
/// A call already in the list is updated rather than duplicated, and keeps its
/// transcript if the incoming copy doesn't have one. Calls named in an incoming
/// call's `replacesCallIds` are dropped.
List<Map<String, dynamic>> mergeCalls(
  List<Map<String, dynamic>> existing,
  Iterable<Map<String, dynamic>> incoming,
) {
  final byId = {for (final call in existing) call['id']: call};

  for (final raw in incoming) {
    final call = normalizeCall(raw);
    final previous = byId[call['id']];
    if (previous != null && (call['transcript'] as String).isEmpty) {
      call['transcript'] = previous['transcript'];
    }
    byId[call['id']] = call;
  }

  for (final call in incoming) {
    final replaced = call['replacesCallIds'];
    if (replaced is List) replaced.forEach(byId.remove);
  }

  return byId.values.toList()
    ..sort((a, b) {
      final byTime =
          (b['startTime'] as int? ?? 0).compareTo(a['startTime'] as int? ?? 0);
      return byTime != 0
          ? byTime
          : b['id'].toString().compareTo(a['id'].toString());
    });
}

/// Builds the playable URL for a call's `audioFile`. The audio host serves
/// files from its root, so the path's leading `audio/` has to be removed.
String audioUrlFor(String audioFile) {
  final path =
      audioFile.startsWith('audio/') ? audioFile.substring(6) : audioFile;
  return '$_audioBaseUrl$path';
}

/// Formats epoch seconds as local time, e.g. `11/2/2026 09:05:03`.
String formatTimestamp(int timestamp) {
  final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${time.month}/${time.day}/${time.year} '
      '${twoDigits(time.hour)}:${twoDigits(time.minute)}:${twoDigits(time.second)}';
}

/// Formats a call's length. Times are whole seconds, so a short call can have
/// the same start and end. Returns an empty string if either time is missing.
String formatDuration(int? startTime, int? endTime) {
  if (startTime == null || endTime == null) return '';
  final seconds = endTime - startTime;
  return seconds < 1 ? '<1 Sec' : '$seconds Sec';
}
