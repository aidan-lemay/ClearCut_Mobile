import 'package:clearcut_mobile/pages/systems_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

const apiTimeout = Duration(seconds: 15);

// A transcribe request may not return until the server has finished the work.
const transcribeTimeout = Duration(seconds: 90);

/* Clearcut API Paths:
Audio: https://audio.clearcutradio.app/audio/[SYSTEM NAME]/[TGID]/[FILE NAME]
URL: https://clearcutradio.app
Systems: /api/v1/systems
Talkgroups: /api/v1/talkgroups?system=[SYSTEM NAME]
Calls: /api/v1/calls?system=[SYSTEM NAME]&talkgroup=[TGID]
Stream: /api/v1/stream?system=[SYSTEM NAME]&talkgroup=[TGID]
Multiple TGs Calls: /api/v1/calls?system=[SYSTEM NAME]&talkgroup=[TGID,TGID,TGID]
Multiple TGs Stream: /api/v1/stream?system=us-ny-monroe&talkgroup=[TGID,TGID,TGID]
More Calls: https://clearcutradio.app/api/v1/calls?system=[SYSTEM NAME]&talkgroup=[TGID]&before_ts=[TIMESTAMP OF LAST CALL]
*/

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'Clearcut Mobile',
        themeMode: ThemeMode.dark,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.greenAccent,
            brightness: Brightness.dark,
          ),
          textTheme: ThemeData.light().textTheme,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.greenAccent,
            brightness: Brightness.dark,
          ),
          textTheme: ThemeData.dark().textTheme,
        ),
        home: MySystemsPage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  dynamic current;
  List<dynamic>? apiData;
  bool systemsFailed = false;
  var favorites = <Map<String, dynamic>>[];

  /// Systems the user added by ID because the systems list doesn't include
  /// them. Each is `{'id': ..., 'name': ...}`, where the name may be empty.
  var hiddenSystems = <Map<String, dynamic>>[];

  MyAppState() {
    fetchSystems();
    loadFavorites();
    loadHiddenSystems();
  }

  /// The fetched systems followed by the hidden ones. A hidden system that
  /// later appears in the fetched list is only shown once.
  List<Map<String, dynamic>> get allSystems {
    final listed = [
      for (final system in apiData ?? []) Map<String, dynamic>.from(system)
    ];
    final listedIds = listed.map((system) => system['id']).toSet();
    return [
      ...listed,
      for (final hidden in hiddenSystems)
        if (!listedIds.contains(hidden['id']))
          {
            'id': hidden['id'],
            'name': hiddenSystemName(hidden),
            'hidden': true,
          },
    ];
  }

  static String hiddenSystemName(Map<String, dynamic> system) {
    final name = (system['name'] as String? ?? '').trim();
    return name.isEmpty ? system['id'] : name;
  }

  bool isListedSystem(String id) =>
      apiData?.any((system) => system['id'] == id) ?? false;

  bool hasHiddenSystem(String id) =>
      hiddenSystems.any((system) => system['id'] == id);

  void addHiddenSystem(String id, {String name = ''}) {
    hiddenSystems.add({'id': id, 'name': name.trim()});
    saveHiddenSystems();
    notifyListeners();
  }

  void updateHiddenSystem(String oldId, String id, String name) {
    final index = hiddenSystems.indexWhere((system) => system['id'] == oldId);
    if (index < 0) return;
    hiddenSystems[index] = {'id': id, 'name': name.trim()};
    saveHiddenSystems();
    notifyListeners();
  }

  void removeHiddenSystem(String id) {
    hiddenSystems.removeWhere((system) => system['id'] == id);
    saveHiddenSystems();
    notifyListeners();
  }

  /// Adds imported hidden systems after the current ones, skipping IDs that
  /// are already there, or replaces them all. Returns how many were added.
  int importHiddenSystems(List<Map<String, dynamic>> incoming,
      {required bool replace}) {
    if (replace) hiddenSystems = [];
    var added = 0;
    for (final system in incoming) {
      if (!hasHiddenSystem(system['id'])) {
        hiddenSystems.add(system);
        added++;
      }
    }
    saveHiddenSystems();
    notifyListeners();
    return added;
  }

  /// Adds imported favorites after the current ones in the order given,
  /// skipping ones already saved, or replaces them all. Returns how many were
  /// added.
  int importFavorites(List<Map<String, dynamic>> incoming,
      {required bool replace}) {
    if (replace) favorites = [];
    var added = 0;
    for (final favorite in incoming) {
      if (!isFavorite(favorite['systemId'], favorite['talkgroups'])) {
        favorites.add(favorite);
        added++;
      }
    }
    saveFavorites();
    notifyListeners();
    return added;
  }

  Future<void> saveHiddenSystems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('hiddenSystems', jsonEncode(hiddenSystems));
    } catch (error) {
      print('Error saving hidden systems: $error');
    }
  }

  Future<void> loadHiddenSystems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('hiddenSystems');
      if (stored != null) {
        hiddenSystems = List<Map<String, dynamic>>.from(jsonDecode(stored));
        notifyListeners();
      }
    } catch (error) {
      print('Error loading hidden systems: $error');
    }
  }

  Future<void> fetchSystems() async {
    systemsFailed = false;
    notifyListeners();

    try {
      final response = await http
          .get(Uri.parse('https://clearcutradio.app/api/v1/systems'))
          .timeout(apiTimeout);

      if (response.statusCode == 200) {
        apiData = json.decode(response.body);
      } else {
        throw Exception('Failed to load data');
      }
    } catch (error) {
      print('Error fetching API data: $error');
      systemsFailed = true;
    }
    notifyListeners();
  }

  Future<List<dynamic>> fetchTalkgroups(String systemId) async {
    try {
      final response = await http
          .get(
            Uri.parse(
                'https://clearcutradio.app/api/v1/talkgroups?system=$systemId'),
          )
          .timeout(apiTimeout);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load talkgroups');
      }
    } catch (error) {
      print('Error fetching talkgroups: $error');
      rethrow;
    }
  }

  void setCurrent(dynamic item) {
    current = item;
    notifyListeners();
  }

  // Talkgroups are compared by ID: the same talkgroup is a different Map object
  // each time it's fetched or loaded from storage, and its other fields change.
  bool _isSameFavorite(
    Map<String, dynamic> favorite,
    String systemId,
    List<dynamic> talkgroups,
  ) {
    Set<dynamic> ids(List<dynamic> list) => list.map((tg) => tg['id']).toSet();
    return favorite['systemId'] == systemId &&
        const SetEquality()
            .equals(ids(favorite['talkgroups']), ids(talkgroups));
  }

  bool isFavorite(String systemId, List<dynamic> talkgroups) {
    return favorites
        .any((favorite) => _isSameFavorite(favorite, systemId, talkgroups));
  }

  void addFavorite(String systemId, List<dynamic> talkgroups) {
    if (!isFavorite(systemId, talkgroups)) {
      favorites.add({'systemId': systemId, 'talkgroups': talkgroups});
      saveFavorites();
      notifyListeners();
    } else {
      print('This favorite already exists.');
    }
  }

  void removeFavorite(String systemId, List<dynamic> talkgroups) {
    favorites.removeWhere(
        (favorite) => _isSameFavorite(favorite, systemId, talkgroups));
    saveFavorites();
    notifyListeners();
  }

  /// Moves a favorite, with indexes as given by ReorderableListView: [newIndex]
  /// is counted before the item is taken out of the list.
  void moveFavorite(int oldIndex, int newIndex) {
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    favorites.insert(target, favorites.removeAt(oldIndex));
    saveFavorites();
    notifyListeners();
  }

  Future<void> saveFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favoritesJson = jsonEncode(favorites);
      await prefs.setString('favorites', favoritesJson);
    } catch (error) {
      print('Error saving favorites: $error');
    }
  }

  Future<void> loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favoritesJson = prefs.getString('favorites');
      if (favoritesJson != null) {
        final stored =
            List<Map<String, dynamic>>.from(jsonDecode(favoritesJson));

        // Earlier versions could save the same favorite more than once.
        favorites = [];
        for (final favorite in stored) {
          if (!isFavorite(favorite['systemId'], favorite['talkgroups'])) {
            favorites.add(favorite);
          }
        }
        if (favorites.length != stored.length) await saveFavorites();

        notifyListeners();
      }
    } catch (error) {
      print('Error loading favorites: $error');
    }
  }
}
