import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import '../services/sse_service.dart';

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
      case 2:
        page = InfoPage();
      case 3:
        page = AdvancedSearch();
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
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.favorite),
              title: Text('Favorites'),
              onTap: () {
                setState(() {
                  selectedIndex = 1;
                });
                Navigator.pop(context);
              },
            ),
            // ListTile(
            //   leading: Icon(Icons.code),
            //   title: Text('Advanced Search'),
            //   onTap: () {
            //     setState(() {
            //       selectedIndex = 3;
            //     });
            //     Navigator.pop(context);
            //   },
            // ),
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Info'),
              onTap: () {
                setState(() {
                  selectedIndex = 2;
                });
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
      body: page,
    );
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
                    side: BorderSide(color: Colors.white, width: 1),
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

class TalkgroupsPage extends StatefulWidget {
  @override
  _TalkgroupsPageState createState() => _TalkgroupsPageState();
}

class _TalkgroupsPageState extends State<TalkgroupsPage> {
  String searchQuery = '';
  bool filterTranscribed = false;
  bool showFavorites = false;
  Map<int, bool> selectedTalkgroups = {};
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
              title: Text(system['name']),
              actions: [
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: IconButton(
                    icon: Icon(Icons.favorite),
                    onPressed: () {
                      setState(() {
                        showFavorites = !showFavorites; // Toggle view
                      });
                    },
                  ),
                ),
              ],
            ),
            body: showFavorites
                ? FavoritesPage()
                : Center(child: CircularProgressIndicator()),
          );
        } else if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(
              title: Text(system['name']),
              actions: [
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: IconButton(
                    icon: Icon(Icons.favorite),
                    onPressed: () {
                      setState(() {
                        showFavorites = !showFavorites; // Toggle view
                      });
                    },
                  ),
                ),
              ],
            ),
            body: showFavorites
                ? FavoritesPage()
                : Center(child: Text('Error loading talkgroups.')),
          );
        } else {
          var talkgroups = snapshot.data ?? [];

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
              actions: [
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: IconButton(
                    icon: Icon(Icons.favorite),
                    onPressed: () {
                      setState(() {
                        showFavorites = !showFavorites; // Toggle view
                      });
                    },
                  ),
                ),
              ],
            ),
            body: showFavorites
                ? FavoritesPage()
                : Column(
                    children: [
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
                              subtitle: Text(
                                  talkgroup['description'] ?? 'No description'),
                              trailing: talkgroup['transcribe'] == true
                                  ? Icon(Icons.check_circle,
                                      color: Colors.green)
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
                      if (selectedTalkgroups.values
                          .any((isSelected) => isSelected))
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: ElevatedButton(
                            onPressed: () {
                              var selected = filteredTalkgroups
                                  .where((tg) =>
                                      selectedTalkgroups[tg['id']] == true)
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
  List<dynamic> callData = [];
  bool isLoading = true;
  bool showFavorites = false;
  String transcriptQuery = '';
  Timer? _refreshTimer;
  late SSEService _sseService;
  late AudioPlayer _audioPlayer;
  int? lastCallTimestamp;

  @override
  void initState() {
    super.initState();
    initializeAudioPlayer();
    fetchInitialCalls();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  void initializeAudioPlayer() {
    _audioPlayer = AudioPlayer();
  }

  // Fetch initial calls and their transcriptions
  Future<void> fetchInitialCalls() async {
    try {
      final systemId = widget.currentSystem;
      final talkgroupIds =
          widget.selectedTalkgroups.map((tg) => tg['id']).join(',');

      final response = await http.get(Uri.parse(
          'https://clearcutradio.app/api/v1/calls?system=$systemId&talkgroup=$talkgroupIds'));

      if (response.statusCode == 200) {
        final initialData = json.decode(response.body);
        setState(() {
          callData = initialData;
          isLoading = false;
        });

        // After initial data is loaded, subscribe to SSE for new calls
        subscribeToSSE();
      } else {
        setState(() {
          isLoading = false;
        });
        throw Exception('Failed to load initial call data');
      }
    } catch (error) {
      setState(() {
        isLoading = false;
      });
      print('Error fetching initial calls: $error');
    }
  }

  // Subscribe to the SSE stream for new calls
  void subscribeToSSE() {
    final talkgroupIds =
        widget.selectedTalkgroups.map((tg) => tg['id']).toList();

    _sseService = SSEService(
      systemName: widget.currentSystem,
      talkgroupIds: talkgroupIds,
    );

    _sseService.startListening((newCall) {
      print('New call received: $newCall');
      setState(() {
        callData.insert(0, newCall); // Insert new call at the top
      });
    });
  }

  // Play audio for the call
  void playAudio(String audioFile) async {
    const baseUrl = 'https://audio.clearcutradio.app/';
    final fullUrl = Uri.parse('$baseUrl$audioFile');

    try {
      if (_audioPlayer.state == PlayerState.playing) {
        await _audioPlayer.stop();
      } else {
        await _audioPlayer.play(UrlSource(fullUrl.toString()));
      }
    } catch (error) {
      print('Error playing/stopping audio: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    String formatTimestamp(int timestamp) {
      final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      return '${dateTime.month}/${dateTime.day}/${dateTime.year} ${dateTime.hour}:${dateTime.minute}:${dateTime.second}';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text("Stream"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Selected Talkgroups: ${widget.selectedTalkgroups.map((tg) => tg['name']).join(', ')}",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                labelText: 'Search Transcripts',
                hintText: 'Enter keyword',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) {
                setState(() {
                  transcriptQuery = value;
                });
              },
            ),
            SizedBox(height: 16),
            if (isLoading)
              Center(child: CircularProgressIndicator())
            else
              Expanded(
                child: ListView.builder(
                  itemCount: callData.length,
                  itemBuilder: (context, index) {
                    final call = callData[index];
                    final transcript = call['transcript'] != null
                        ? call['transcript']['text'] ?? ''
                        : '';
                    final talkgroupName = widget.selectedTalkgroups.firstWhere(
                      (tg) => tg['id'] == call['talkgroup'],
                      orElse: () => {'name': 'Unknown Talkgroup'},
                    )['name'];

                    if (!transcript
                        .toLowerCase()
                        .contains(transcriptQuery.toLowerCase())) {
                      return SizedBox.shrink();
                    }

                    return Card(
                      margin: EdgeInsets.symmetric(vertical: 8),
                      child: ListTile(
                        title: Text(
                          talkgroupName,
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(transcript, style: TextStyle(fontSize: 14)),
                            SizedBox(height: 10),
                            Text(
                              call['startTime'] != null
                                  ? formatTimestamp(call['startTime'])
                                  : 'Loading...',
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
          ],
        ),
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

    return ListView.builder(
      itemCount: appState.favorites.length,
      itemBuilder: (context, index) {
        final favorite = appState.favorites[index];
        final talkgroupNames =
            favorite['talkgroups'].map((tg) => tg['name']).join(', ');

        return ListTile(
          leading: Icon(Icons.favorite),
          title: Text(talkgroupNames),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ListenerPage(
                  selectedTalkgroups: favorite['talkgroups'],
                  currentSystem: favorite['systemId'],
                ),
              ),
            );
          },
          trailing: IconButton(
              onPressed: () {
                appState.removeFavorite(
                    favorite['systemId'], favorite['talkgroups']);
              },
              icon: Icon(Icons.delete)),
        );
      },
    );
  }
}

class InfoPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var github = Uri.parse("https://github.com/aidan-lemay/ClearCut_Mobile");
    var mysite = Uri.parse("https://aidanlemay.com");
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path:
          'clearcutfeedback@aidanlemay.com', // Replace with your email address
      query: Uri.encodeQueryComponent(
          'subject=Clearcut Mobile Feedback Request'), // Optional subject and body
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center, // Center content vertically
      children: [
        Text(
          "Welcome to Clearcut Mobile!",
          style: TextStyle(fontSize: 32),
          textAlign: TextAlign.center,
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(
            "Created by Aidan LeMay",
            style: TextStyle(fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: ElevatedButton(
            onPressed: () async {
              if (await canLaunchUrl(github)) {
                await launchUrl(github);
              } else {
                await Clipboard.setData(ClipboardData(text: github.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        "Couldn't open link, copied to clipboard instead!"),
                  ),
                );
              }
            },
            child: Text('Check Out This Project on GitHub!'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: ElevatedButton(
            onPressed: () async {
              if (await canLaunchUrl(mysite)) {
                await launchUrl(mysite);
              } else {
                await Clipboard.setData(ClipboardData(text: mysite.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        "Couldn't open link, copied to clipboard instead!"),
                  ),
                );
              }
            },
            child: Text('Check Out My Website!'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: ElevatedButton(
            onPressed: () async {
              if (await canLaunchUrl(emailUri)) {
                await launchUrl(emailUri);
              } else {
                await Clipboard.setData(
                    ClipboardData(text: emailUri.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      "Couldn't open email app, copied address to clipboard instead!",
                    ),
                  ),
                );
              }
            },
            child: Text('Have Feedback? Email Me!'),
          ),
        ),
      ],
    );
  }
}

class AdvancedSearch extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(child: Text("Advanced Search Coming Soon?"));
  }
}
