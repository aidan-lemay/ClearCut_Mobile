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
        home: MySystemsPage(),
      ),
    );
  }
}

class MySystemsPage extends StatefulWidget {
  @override
  State<MySystemsPage> createState() => _MySystemsPageState();
}

class _MySystemsPageState extends State<MySystemsPage> {
  var selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    Widget page;
    switch (selectedIndex) {
      case 0:
        page = SystemsPage();
      case 1:
        page = FavoritesPage();
      default:
        throw UnimplementedError('No widget for $selectedIndex');
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Systems'),
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
                'Clearcut Mobile',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.storage_rounded),
              title: Text('Systems'),
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

class MyAppState extends ChangeNotifier {
  dynamic current; // Typing can be specific if the API structure is known
  List<dynamic>? apiData; // Holds the API data
  var favorites = <dynamic>[]; // List of favorites

  MyAppState() {
    fetchSystems(); // Automatically fetch data on initialization
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
    current = item; // Update 'current'
    notifyListeners(); // Notify listeners about the change
  }
}

class SystemsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (appState.apiData != null)
            ...appState.apiData!.map((x) {
              return Padding(
                padding: const EdgeInsets.all(10.0),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.black, width: 1),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  contentPadding: EdgeInsets.all(3),
                  horizontalTitleGap: 10,
                  title: Text(x['name']),
                  onTap: () {
                    appState.setCurrent(x);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => TalkgroupsPage(),
                      ),
                    );
                  },
                ),
              );
            }).toList(),
          if (appState.apiData == null) CircularProgressIndicator(),
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

class TalkgroupsPage extends StatefulWidget {
  @override
  _TalkgroupsPageState createState() => _TalkgroupsPageState();
}

class _TalkgroupsPageState extends State<TalkgroupsPage> {
  Map<int, bool> selectedTalkgroups = {}; // Tracks selected talkgroups

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();
    var system = appState.current;

    if (system == null || system is! Map || !system.containsKey('id')) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Talkgroups'),
        ),
        body: Center(
          child: Text('No system selected.'),
        ),
      );
    }

    return FutureBuilder(
      future: appState.fetchTalkgroups(system['id']),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(
              title: Text('Talkgroups'),
            ),
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        } else if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(
              title: Text('Talkgroups'),
            ),
            body: Center(
              child: Text('Error loading talkgroups.'),
            ),
          );
        } else {
          var talkgroups = snapshot.data as List;

          return Scaffold(
            appBar: AppBar(
              title: Text(system['name']),
            ),
            body: ListView.builder(
              itemCount: talkgroups.length,
              itemBuilder: (context, index) {
                var talkgroup = talkgroups[index];
                bool isSelected = selectedTalkgroups[talkgroup['id']] ?? false;

                return Column(
                  children: [
                    ListTile(
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (bool? newValue) {
                          setState(() {
                            selectedTalkgroups[talkgroup['id']] =
                                newValue ?? false;
                          });
                        },
                      ),
                      title: Text(talkgroup['name']),
                      subtitle:
                          Text(talkgroup['description'] ?? 'No description'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ListenerPage(
                              selectedTalkgroups: [talkgroup],
                            ),
                          ),
                        );
                      },
                    ),
                    Divider(),
                  ],
                );
              },
            ),
            floatingActionButton: selectedTalkgroups.containsValue(true)
                ? FloatingActionButton.extended(
                    onPressed: () {
                      var selectedItems = talkgroups
                          .where((tg) => selectedTalkgroups[tg['id']] ?? false);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ListenerPage(
                            selectedTalkgroups: selectedItems.toList(),
                          ),
                        ),
                      );
                    },
                    label: Text('Listen to Selected'),
                    icon: Icon(Icons.play_arrow),
                  )
                : null,
          );
        }
      },
    );
  }
}

class ListenerPage extends StatelessWidget {
  final List<dynamic> selectedTalkgroups;

  ListenerPage({required this.selectedTalkgroups});

  @override
  Widget build(BuildContext context) {
    final talkgroupNames =
        selectedTalkgroups.map((tg) => tg['name']).join(', ');

    return Scaffold(
      appBar: AppBar(
        title: Text('Listener'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              talkgroupNames.isNotEmpty
                  ? "Selected Talkgroups: $talkgroupNames"
                  : 'No talkgroups selected.',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
