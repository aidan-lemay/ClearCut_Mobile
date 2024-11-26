import 'package:clearcut_mobile/pages/systems_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:flutter/services.dart';

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
      child: Consumer<MyAppState>(
        builder: (context, appState, _) {
          return MaterialApp(
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
          );
        },
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  dynamic current;
  List<dynamic>? apiData;
  var favorites = <Map<String, dynamic>>[];

  MyAppState() {
    fetchSystems();
    loadFavorites();
  }

  Future<void> fetchSystems() async {
    try {
      final response =
          await http.get(Uri.parse('https://clearcutradio.app/api/v1/systems'));

      if (response.statusCode == 200) {
        apiData = json.decode(response.body);
        notifyListeners();
      } else {
        throw Exception('Failed to load data');
      }
    } catch (error) {
      print('Error fetching API data: $error');
    }
  }

  Future<List<dynamic>> fetchTalkgroups(String systemId) async {
    try {
      final response = await http.get(
        Uri.parse(
            'https://clearcutradio.app/api/v1/talkgroups?system=$systemId'),
      );

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

  void addFavorite(String systemId, List<dynamic> talkgroups) {
    bool alreadyExists = favorites.any((favorite) {
      return favorite['systemId'] == systemId &&
          ListEquality().equals(favorite['talkgroups'], talkgroups);
    });

    if (!alreadyExists) {
      favorites.add({'systemId': systemId, 'talkgroups': talkgroups});
      saveFavorites();
      notifyListeners();
    } else {
      print('This favorite already exists.');
    }
  }

  void removeFavorite(String systemId, List<dynamic> talkgroups) {
    favorites.removeWhere((favorite) =>
        favorite['systemId'] == systemId &&
        ListEquality().equals(favorite['talkgroups'], talkgroups));
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
        favorites = List<Map<String, dynamic>>.from(jsonDecode(favoritesJson));
        notifyListeners();
      }
    } catch (error) {
      print('Error loading favorites: $error');
    }
  }
}
