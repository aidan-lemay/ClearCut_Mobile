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
  final _searchController = TextEditingController();
  String searchQuery = '';
  bool filterTranscribed = false;
  bool showFavorites = false;
  Map<int, bool> selectedTalkgroups = {};

  dynamic _system;

  // Fetched once and kept here: creating the future in build() would re-fetch
  // and swap the page for a spinner on every keystroke and checkbox tap.
  Future<List<dynamic>>? _talkgroupsFuture;

  bool get _hasSystem => _system is Map && (_system as Map).containsKey('id');

  @override
  void initState() {
    super.initState();
    _system = context.read<MyAppState>().current;
    if (_hasSystem) _loadTalkgroups();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadTalkgroups() {
    _talkgroupsFuture =
        context.read<MyAppState>().fetchTalkgroups(_system['id']);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_hasSystem ? _system['name'] : 'Talkgroups'),
        actions: [
          FavoritesToggleButton(
            isShowingFavorites: showFavorites,
            onPressed: () {
              setState(() {
                showFavorites = !showFavorites; // Toggle view
              });
            },
          ),
        ],
      ),
      body: showFavorites
          ? FavoritesPage()
          : !_hasSystem
              ? Center(child: Text('No system selected.'))
              : FutureBuilder<List<dynamic>>(
                  future: _talkgroupsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _buildError();
                    }
                    final talkgroups = snapshot.data ?? [];
                    if (talkgroups.isEmpty) {
                      return Center(
                        child: Text('No talkgroups found for this system.'),
                      );
                    }
                    return _buildTalkgroups(talkgroups);
                  },
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Error loading talkgroups.'),
          SizedBox(height: 8),
          ElevatedButton(
            onPressed: () {
              setState(_loadTalkgroups);
            },
            child: Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildTalkgroups(List<dynamic> talkgroups) {
    final query = searchQuery.toLowerCase();
    final filteredTalkgroups = talkgroups.where((tg) {
      final matchesQuery = (tg['name'] ?? '')
              .toString()
              .toLowerCase()
              .contains(query) ||
          (tg['description'] ?? '').toString().toLowerCase().contains(query) ||
          tg['id'].toString().contains(query);
      final matchesTranscribed =
          !filterTranscribed || (tg['transcribe'] == true);
      return matchesQuery && matchesTranscribed;
    }).toList();

    // Taken from the full list so a selection stays in place when a search or
    // filter hides it.
    final selected =
        talkgroups.where((tg) => selectedTalkgroups[tg['id']] == true).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
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
              Expanded(child: Text('Show only transcribed talkgroups')),
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
              var isSelected = selectedTalkgroups[talkgroup['id']] ?? false;

              return ListTile(
                leading: Checkbox(
                  value: isSelected,
                  onChanged: (bool? newValue) {
                    setState(() {
                      selectedTalkgroups[talkgroup['id']] = newValue ?? false;
                    });
                  },
                ),
                title: Text(talkgroup['name']),
                subtitle: Text(talkgroup['description'] ?? 'No description'),
                trailing: talkgroup['transcribe'] == true
                    ? Icon(Icons.check_circle, color: Colors.green)
                    : null,
                onTap: () => _openListener([talkgroup]),
              );
            },
          ),
        ),
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton(
              onPressed: () => _openListener(selected),
              child: Text('Listen to Selected (${selected.length})'),
            ),
          ),
      ],
    );
  }

  void _openListener(List<dynamic> talkgroups) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ListenerPage(
          selectedTalkgroups: talkgroups,
          currentSystem: _system['id'],
        ),
      ),
    );
  }
}
