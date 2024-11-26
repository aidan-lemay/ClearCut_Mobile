import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/favorites_page.dart';
import 'package:clearcut_mobile/pages/listener_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
