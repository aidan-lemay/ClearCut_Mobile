import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

/* Clearcut API Paths:
URL: https://clearcutradio.app
Systems: /api/v1/systems
Talkgroups: /api/v1/talkgroups?system=[SYSTEM NAME]
Calls: /api/v1/calls?system=[SYSTEM NAME]&talkgroup=[TGID]
Stream: /api/v1/stream?system=us-ny-monroe&talkgroup=[TGID]
Multiple TGs Calls: /api/v1/calls?system=[SYSTEM NAME]&talkgroup=[TGID,TGID,TGID]
Multiple TGs Stream: /api/v1/stream?system=us-ny-monroe&talkgroup=[TGID,TGID,TGID]
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
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.greenAccent),
        ),
        home: MyHomePage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  var current;
  List<dynamic>? apiData; // Ensure this is nullable
  var favorites = <dynamic>[]; // Adjust type to accommodate dynamic data

  MyAppState() {
    fetchApiData();
  }

  Future<void> fetchApiData() async {
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

  void toggleFavorite(dynamic item) {
    if (favorites.contains(item)) {
      favorites.remove(item);
    } else {
      favorites.add(item);
    }
    notifyListeners();
  }
}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  var selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    Widget page;
    switch (selectedIndex) {
      case 0:
        page = HomePage();
      case 1:
        page = FavoritesPage();
      default:
        throw UnimplementedError('No widget for $selectedIndex');
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Clearcut Mobile'),
        leading: Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: Text(
                'Navigation',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.home),
              title: Text('Home'),
              onTap: () {
                setState(() {
                  selectedIndex = 0;
                });
                Navigator.pop(context); // Close the drawer
              },
            ),
            ListTile(
              leading: Icon(Icons.favorite),
              title: Text('Favorites'),
              onTap: () {
                setState(() {
                  selectedIndex = 1;
                });
                Navigator.pop(context); // Close the drawer
              },
            ),
          ],
        ),
      ),
      body: page,
    );
  }
}

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 20),
          if (appState.apiData != null)
            ...appState.apiData!.map(
              (x) => ListTile(
                title: Text(x['name']), // Correctly access the 'name' field
                trailing: IconButton(
                  icon: Icon(
                    appState.favorites.contains(x)
                        ? Icons.favorite
                        : Icons.favorite_border,
                  ),
                  onPressed: () {
                    appState.toggleFavorite(x);
                  },
                ),
              ),
            ),
          if (appState.apiData == null)
            CircularProgressIndicator(), // Loader when fetching data
        ],
      ),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    if (appState.favorites.isEmpty) {
      return Center(
        child: Text('No favorites yet.'),
      );
    }

    return ListView(
      children: appState.favorites.map((item) {
        return ListTile(
          leading: Icon(Icons.favorite),
          title: Text(item['name']),
        );
      }).toList(),
    );
  }
}
