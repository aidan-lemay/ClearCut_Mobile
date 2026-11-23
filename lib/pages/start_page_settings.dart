import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/services/start_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The Settings entry for choosing which page the app opens on.
class StartPageSetting extends StatelessWidget {
  const StartPageSetting({super.key});

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _choose(BuildContext context) async {
    final appState = context.read<MyAppState>();
    final current = appState.startPage.kind;

    Widget option(StartPageKind kind, IconData icon, String title,
            [String? subtitle]) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: kind == current ? Icon(Icons.check) : null,
          onTap: () => Navigator.of(context).pop(kind),
        );

    final kind = await showModalBottomSheet<StartPageKind>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Open the app on',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            option(StartPageKind.systems, Icons.storage_rounded,
                'Systems', 'The list of all systems'),
            option(StartPageKind.favorites, Icons.favorite, 'Favorites',
                'Your list of favorites'),
            option(StartPageKind.system, Icons.cell_tower, 'A System',
                'That system\'s talkgroups'),
            option(StartPageKind.talkgroups, Icons.radio, 'Talkgroups',
                'Listen to one talkgroup, a group of them, or a favorite'),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;

    final Future<StartPage?> picked = switch (kind) {
      StartPageKind.systems => Future.value(StartPage.systems),
      StartPageKind.favorites => Future.value(StartPage.favorites),
      StartPageKind.system => _pickSystem(context, 'Start on a System'),
      StartPageKind.talkgroups => _pickTalkgroups(context),
    };
    final page = await picked;
    if (page == null || !context.mounted) return;
    appState.setStartPage(page);
    _showMessage(context, 'The app will open on ${page.description}.');
  }

  /// Returns null if cancelled.
  Future<StartPage?> _pickSystem(BuildContext context, String title) async {
    final systems = context.read<MyAppState>().allSystems;
    if (systems.isEmpty) {
      _showMessage(context, 'Systems haven\'t loaded yet. Try again shortly.');
      return null;
    }
    return showDialog<StartPage>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          for (final system in systems)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context)
                  .pop(StartPage.system(system['id'], system['name'])),
              child: Text(system['name']),
            ),
        ],
      ),
    );
  }

  /// Picks from favorites, or talkgroups chosen from a system. Returns null
  /// if cancelled.
  Future<StartPage?> _pickTalkgroups(BuildContext context) async {
    final appState = context.read<MyAppState>();
    final systemNames = {
      for (final system in appState.allSystems) system['id']: system['name']
    };
    String systemName(String id) => systemNames[id] ?? id;

    // The favorites are offered first, as the quickest way to a group.
    const chooseFromSystem = 'system';
    final choice = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Start on Talkgroups'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(chooseFromSystem),
            child: Row(
              children: [
                Icon(Icons.checklist),
                SizedBox(width: 12),
                Expanded(child: Text('Choose from a system...')),
              ],
            ),
          ),
          if (appState.favorites.isNotEmpty) ...[
            Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
              child: Text('Or pick a favorite',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
          ],
          for (final favorite in appState.favorites)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(favorite),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((favorite['talkgroups'] as List)
                      .map((tg) => tg['name'])
                      .join(', ')),
                  Text(
                    systemName(favorite['systemId']),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return null;

    if (choice is Map) {
      final systemId = choice['systemId'] as String;
      return StartPage.talkgroups(
          systemId, systemName(systemId), choice['talkgroups']);
    }

    final system = await _pickSystem(context, 'Choose a System');
    if (system == null || !context.mounted) return null;
    final talkgroups = await Navigator.of(context).push<List<dynamic>>(
      MaterialPageRoute(
        builder: (context) => PickTalkgroupsPage(
            systemId: system.systemId, systemName: system.systemName),
      ),
    );
    if (talkgroups == null || talkgroups.isEmpty) return null;
    return StartPage.talkgroups(
        system.systemId, system.systemName, talkgroups);
  }

  @override
  Widget build(BuildContext context) {
    final startPage = context.watch<MyAppState>().startPage;
    return ListTile(
      leading: Icon(Icons.home),
      title: Text('Start Page'),
      subtitle: Text(startPage.description),
      trailing: Icon(Icons.chevron_right),
      onTap: () => _choose(context),
    );
  }
}

/// Picks one or more of a system's talkgroups. Pops the chosen talkgroups.
class PickTalkgroupsPage extends StatefulWidget {
  final String systemId;
  final String systemName;

  const PickTalkgroupsPage(
      {super.key, required this.systemId, required this.systemName});

  @override
  State<PickTalkgroupsPage> createState() => _PickTalkgroupsPageState();
}

class _PickTalkgroupsPageState extends State<PickTalkgroupsPage> {
  late Future<List<dynamic>> _talkgroups = _load();
  final _selected = <int>{};
  String _query = '';

  Future<List<dynamic>> _load() =>
      context.read<MyAppState>().fetchTalkgroups(widget.systemId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.systemName)),
      body: FutureBuilder<List<dynamic>>(
        future: _talkgroups,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Error loading talkgroups.'),
                  SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () => setState(() => _talkgroups = _load()),
                    child: Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final talkgroups = snapshot.data ?? [];
          if (talkgroups.isEmpty) {
            return Center(child: Text('No talkgroups found for this system.'));
          }
          return _buildList(talkgroups);
        },
      ),
    );
  }

  Widget _buildList(List<dynamic> talkgroups) {
    final query = _query.toLowerCase();
    final shown = talkgroups
        .where((tg) =>
            (tg['name'] ?? '').toString().toLowerCase().contains(query) ||
            (tg['description'] ?? '')
                .toString()
                .toLowerCase()
                .contains(query) ||
            tg['id'].toString().contains(query))
        .toList();
    // In the system's order, wherever they were ticked from.
    final selected =
        talkgroups.where((tg) => _selected.contains(tg['id'])).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: InputDecoration(
              labelText: 'Search Talkgroups',
              hintText: 'Enter name, description, or ID',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, index) {
              final tg = shown[index];
              return CheckboxListTile(
                controlAffinity: ListTileControlAffinity.leading,
                value: _selected.contains(tg['id']),
                title: Text(tg['name']),
                subtitle: Text(tg['description'] ?? 'No description'),
                onChanged: (ticked) => setState(() => ticked == true
                    ? _selected.add(tg['id'])
                    : _selected.remove(tg['id'])),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(selected),
            child: Text(selected.isEmpty
                ? 'Tick talkgroups to start on'
                : 'Start on ${selected.length == 1 ? 'This Talkgroup' : 'These ${selected.length} Talkgroups'}'),
          ),
        ),
      ],
    );
  }
}
