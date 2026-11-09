/// Notification rules, as sent by the app, and how calls are matched to them.
library;

enum RuleMode {
  /// Every call, and again with its transcript when one arrives.
  all,

  /// Every transcript.
  transcripts,

  /// Transcripts containing one of the rule's keywords.
  keywords,
}

final _systemIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

const maxRulesPerDevice = 50;
const maxTalkgroupsPerRule = 1000;
const maxKeywordsPerRule = 50;

/// Each system is a separate Clearcut connection, so this keeps one phone
/// from opening dozens.
const maxSystemsPerDevice = 10;

class Rule {
  final String id;
  final String name;
  final bool enabled;
  final String systemId;

  /// Talkgroup ID to name. Upload events carry only the ID, so names come
  /// from here.
  final Map<int, String> talkgroups;
  final RuleMode mode;
  final List<String> keywords;
  final List<RegExp> _patterns;

  Rule({
    required this.id,
    required this.name,
    required this.enabled,
    required this.systemId,
    required this.talkgroups,
    required this.mode,
    required this.keywords,
  }) : _patterns = keywords.map(keywordPattern).toList();

  /// Parses and checks a rule from the app. Throws [FormatException] with a
  /// message the app can show.
  factory Rule.fromJson(Object? json) {
    if (json is! Map) throw FormatException('A rule must be an object.');
    String text(String field, int maxLength) {
      final value = json[field];
      if (value is! String || value.length > maxLength) {
        throw FormatException(
          'Rule $field must be text of at most '
          '$maxLength characters.',
        );
      }
      return value;
    }

    final id = text('id', 100);
    final name = text('name', 100);
    final systemId = text('systemId', 100);
    if (!_systemIdPattern.hasMatch(systemId)) {
      throw FormatException('Rule "$name" has an invalid system ID.');
    }

    final enabled = json['enabled'];
    if (enabled is! bool) {
      throw FormatException('Rule "$name" needs enabled set to true or false.');
    }

    final mode = RuleMode.values.asNameMap()[json['mode']];
    if (mode == null) {
      throw FormatException('Rule "$name" has an unknown mode.');
    }

    final rawTalkgroups = json['talkgroups'];
    if (rawTalkgroups is! List ||
        rawTalkgroups.isEmpty ||
        rawTalkgroups.length > maxTalkgroupsPerRule) {
      throw FormatException(
        'Rule "$name" needs 1 to $maxTalkgroupsPerRule '
        'talkgroups.',
      );
    }
    final talkgroups = <int, String>{};
    for (final tg in rawTalkgroups) {
      if (tg is! Map || tg['id'] is! int) {
        throw FormatException('Rule "$name" has an invalid talkgroup.');
      }
      final tgName = tg['name'];
      talkgroups[tg['id']] = tgName is String && tgName.length <= 200
          ? tgName
          : 'Talkgroup ${tg['id']}';
    }

    final rawKeywords = json['keywords'] ?? [];
    if (rawKeywords is! List || rawKeywords.length > maxKeywordsPerRule) {
      throw FormatException(
        'Rule "$name" can have at most '
        '$maxKeywordsPerRule keywords.',
      );
    }
    final keywords = <String>[];
    for (final keyword in rawKeywords) {
      if (keyword is! String || keyword.length > 100) {
        throw FormatException('Rule "$name" has an invalid keyword.');
      }
      final trimmed = keyword.trim();
      if (trimmed.replaceAll('*', '').isNotEmpty) keywords.add(trimmed);
    }
    if (mode == RuleMode.keywords && keywords.isEmpty) {
      throw FormatException('Rule "$name" needs at least one keyword.');
    }

    return Rule(
      id: id,
      name: name,
      enabled: enabled,
      systemId: systemId,
      talkgroups: talkgroups,
      mode: mode,
      keywords: keywords,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'systemId': systemId,
    'talkgroups': [
      for (final entry in talkgroups.entries)
        {'id': entry.key, 'name': entry.value},
    ],
    'mode': mode.name,
    'keywords': keywords,
  };

  bool watches(String system, int talkgroup) =>
      enabled && system == systemId && talkgroups.containsKey(talkgroup);

  /// The keywords found in [text], in the rule's order.
  List<String> matchingKeywords(String text) => [
    for (var i = 0; i < keywords.length; i++)
      if (_patterns[i].hasMatch(text)) keywords[i],
  ];
}

/// Matches [keyword] as whole words, ignoring case, so "fire" matches
/// "Fire!" but not "firearm". A trailing `*` matches any ending instead, so
/// "fire*" matches both. Runs of spaces in a phrase match any whitespace.
RegExp keywordPattern(String keyword) {
  var core = keyword.trim();
  final prefix = core.endsWith('*');
  core = core.replaceAll('*', '').trim();
  final escaped = core.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s+');
  final end = prefix ? '' : r'(?![\p{L}\p{N}])';
  return RegExp(
    '(?<![\\p{L}\\p{N}])$escaped$end',
    caseSensitive: false,
    unicode: true,
  );
}
