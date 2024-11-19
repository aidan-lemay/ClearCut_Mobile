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
  String searchQuery = ''; // Store the search query
  bool filterTranscribed = false; // Store the filter state
  Map<int, bool> selectedTalkgroups = {}; // Track selected talkgroups
  String currentSystem = "";

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

    currentSystem = system['id'];

    return FutureBuilder<List<dynamic>>(
      future: appState.fetchTalkgroups(system['id']),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(
              title: Text('Talkgroups'),
            ),
            body: Center(child: CircularProgressIndicator()),
          );
        } else if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(
              title: Text('Talkgroups'),
            ),
            body: Center(child: Text('Error loading talkgroups.')),
          );
        } else {
          var talkgroups = snapshot.data ?? [];

          // Filter talkgroups based on search query and "transcribed" filter
          var filteredTalkgroups = talkgroups.where((tg) {
            final matchesQuery = tg['name']
                    .toString()
                    .toLowerCase()
                    .contains(searchQuery.toLowerCase()) ||
                tg['description']
                    .toString()
                    .toLowerCase()
                    .contains(searchQuery.toLowerCase()) ||
                tg['id']
                    .toString()
                    .toLowerCase()
                    .contains(searchQuery.toLowerCase());
            final matchesTranscribed =
                !filterTranscribed || (tg['transcribe'] == true);
            return matchesQuery && matchesTranscribed;
          }).toList();

          return Scaffold(
            appBar: AppBar(
              title: Text(system['name']),
            ),
            body: Column(
              children: [
                // Search Bar
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: 'Search Talkgroups',
                      hintText: 'Enter name, description, or ID',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setState(() {
                        searchQuery = value;
                      });
                    },
                  ),
                ),

                // Transcription Filter
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Show only transcribed talkgroups'),
                      Switch(
                        value: filterTranscribed,
                        onChanged: (value) {
                          setState(() {
                            filterTranscribed = value;
                          });
                        },
                      ),
                    ],
                  ),
                ),

                // Talkgroup List
                Expanded(
                  child: ListView.builder(
                    itemCount: filteredTalkgroups.length,
                    itemBuilder: (context, index) {
                      var talkgroup = filteredTalkgroups[index];
                      var isSelected =
                          selectedTalkgroups[talkgroup['id']] ?? false;

                      return ListTile(
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
                        trailing: talkgroup['transcribe'] == true
                            ? Icon(Icons.check_circle, color: Colors.green)
                            : null,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ListenerPage(
                                selectedTalkgroups: [talkgroup],
                                currentSystem: currentSystem,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                // Listen to Selected Button
                if (selectedTalkgroups.values.any((isSelected) => isSelected))
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: ElevatedButton(
                      onPressed: () {
                        var selected = filteredTalkgroups
                            .where((tg) => selectedTalkgroups[tg['id']] == true)
                            .toList();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ListenerPage(
                              selectedTalkgroups: selected,
                              currentSystem: currentSystem,
                            ),
                          ),
                        );
                      },
                      child: Text('Listen to Selected'),
                    ),
                  ),
              ],
            ),
          );
        }
      },
    );
  }
}

class ListenerPage extends StatefulWidget {
  final List<dynamic> selectedTalkgroups;
  final String currentSystem;

  ListenerPage({required this.selectedTalkgroups, required this.currentSystem});

  @override
  _ListenerPageState createState() => _ListenerPageState();
}

class _ListenerPageState extends State<ListenerPage> {
  List<dynamic>? callData; // Holds the fetched call data
  bool isLoading = true; // Tracks loading state
  String? errorMessage; // Tracks error messages

  @override
  void initState() {
    super.initState();
    fetchCalls();
  }

  Future<void> fetchCalls() async {
    try {
      final systemId = widget.currentSystem;
      final talkgroupIds =
          widget.selectedTalkgroups.map((tg) => tg['id']).join(',');

      final url = widget.selectedTalkgroups.length == 1
          ? 'https://clearcutradio.app/api/v1/calls?system=$systemId&talkgroup=$talkgroupIds'
          : 'https://clearcutradio.app/api/v1/calls?system=$systemId&talkgroup=$talkgroupIds';

      final response = await http.get(Uri.parse(url));

      print(widget.currentSystem);
      print(widget.selectedTalkgroups);

      if (response.statusCode == 200) {
        setState(() {
          callData = json.decode(response.body);
          isLoading = false;
        });
      } else {
        throw Exception('Failed to fetch call data');
      }
    } catch (error) {
      setState(() {
        errorMessage = error.toString();
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final talkgroupNames =
        widget.selectedTalkgroups.map((tg) => tg['name']).join(', ');

    String formatTimestamp(int timestamp) {
      final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      return '${dateTime.hour}:${dateTime.minute}:${dateTime.second}';
    }

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
              "Selected Talkgroups: $talkgroupNames",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            if (isLoading) ...[
              Center(child: CircularProgressIndicator()),
            ] else if (errorMessage != null) ...[
              Center(child: Text('Error: $errorMessage')),
            ] else if (callData != null && callData!.isNotEmpty) ...[
              Expanded(
                child: ListView.builder(
                  itemCount: callData!.length,
                  itemBuilder: (context, index) {
                    final call = callData![index];
                    final transcript = call['transcript']['text'] ?? '';

                    // Cross-reference talkgroup name
                    final talkgroupName = widget.selectedTalkgroups.firstWhere(
                      (tg) => tg['id'] == call['talkgroup'],
                      orElse: () => {'name': 'Unknown Talkgroup'},
                    )['name'];

                    return Card(
                      margin: EdgeInsets.symmetric(vertical: 8),
                      child: ListTile(
                        title: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            talkgroupName,
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              transcript,
                              style: TextStyle(fontSize: 14),
                            ),
                            SizedBox(height: 10),
                            // Timestamp at the bottom
                            Text(
                              formatTimestamp(call['startTime']),
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.play_arrow),
                          onPressed: () {
                            playAudio(call['audioFile']);
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else ...[
              Center(child: Text('No calls available.')),
            ],
          ],
        ),
      ),
    );
  }

  void playAudio(String audioFile) {
    // Placeholder: Integrate an audio player package to play the audio file
    print('Playing audio: $audioFile');
  }
}
