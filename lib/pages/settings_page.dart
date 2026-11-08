import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/notification_settings.dart';
import 'package:clearcut_mobile/services/backup.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SettingsPage extends StatefulWidget {
  final BackupFiles files;

  const SettingsPage({super.key, this.files = const DeviceBackupFiles()});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _idController = TextEditingController();
  bool _checking = false;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Why [id] can't be used, or null if it can. [currentId] is the system
  /// being edited, which may keep its own ID.
  String? _idProblem(String id, {String? currentId}) {
    final appState = context.read<MyAppState>();
    if (id.isEmpty) return 'Enter a system ID.';
    if (!isValidSystemId(id)) {
      return 'System IDs only use letters, numbers, dots, dashes and '
          'underscores, as in very-bad.';
    }
    if (appState.isListedSystem(id)) {
      return '"$id" is already on the Systems page.';
    }
    if (id != currentId && appState.hasHiddenSystem(id)) {
      return 'You\'ve already added "$id".';
    }
    return null;
  }

  /// Looks the system up, since a typo would otherwise add an empty system.
  /// Returns whether to go ahead.
  Future<bool> _checkSystemExists(String id) async {
    setState(() => _checking = true);
    String? warning;
    try {
      final talkgroups = await context.read<MyAppState>().fetchTalkgroups(id);
      if (talkgroups.isEmpty) {
        warning = 'Clearcut has no talkgroups for "$id". Check the ID for '
            'typos.';
      }
    } catch (_) {
      warning = 'Couldn\'t reach Clearcut to check "$id".';
    }
    if (!mounted) return false;
    setState(() => _checking = false);
    if (warning == null) return true;
    return _confirm('Add this system?', warning, 'Add Anyway');
  }

  Future<void> _addSystem() async {
    final id = _idController.text.trim();
    final problem = _idProblem(id);
    if (problem != null) {
      _showMessage(problem);
      return;
    }
    if (!await _checkSystemExists(id) || !mounted) return;
    context.read<MyAppState>().addHiddenSystem(id);
    _idController.clear();
    FocusScope.of(context).unfocus();
    _showMessage('Added $id to the Systems page.');
  }

  Future<void> _editSystem(Map<String, dynamic> system) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => _EditSystemDialog(
        system: system,
        idProblem: (id) => _idProblem(id, currentId: system['id']),
      ),
    );
    if (result == null || !mounted) return;
    final (id, name) = result;
    if (id != system['id'] && !await _checkSystemExists(id)) return;
    if (!mounted) return;
    context.read<MyAppState>().updateHiddenSystem(system['id'], id, name);
  }

  Future<void> _removeSystem(Map<String, dynamic> system) async {
    final name = MyAppState.hiddenSystemName(system);
    final confirmed = await _confirm(
      'Remove $name?',
      'It will no longer appear on the Systems page. Favorites from it keep '
          'working.',
      'Remove',
    );
    if (confirmed && mounted) {
      context.read<MyAppState>().removeHiddenSystem(system['id']);
    }
  }

  String _fileName(String kind) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return 'clearcut-$kind-$today.json';
  }

  Future<void> _save(String fileName, String contents, String saved) async {
    try {
      if (await widget.files.save(fileName, contents) && mounted) {
        _showMessage(saved);
      }
    } catch (error) {
      print('Error saving backup: $error');
      if (mounted) _showMessage('Couldn\'t save the file.');
    }
  }

  Future<String?> _open() async {
    try {
      return await widget.files.open();
    } catch (error) {
      print('Error opening backup: $error');
      if (mounted) _showMessage('Couldn\'t open that file.');
      return null;
    }
  }

  /// Asks whether imported items replace the current ones or are added after
  /// them. Returns null if the user cancelled. Nothing to ask when there's
  /// nothing to replace.
  Future<bool?> _askReplace(
      String what, String incoming, bool hasCurrent) async {
    if (!hasCurrent) return false;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Import $incoming'),
        content: Text('Add them after your current $what, or replace your '
            'current $what with them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Replace'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Add'),
          ),
        ],
      ),
    );
  }

  static String _count(int n, String one, String many) =>
      n == 1 ? '1 $one' : '$n $many';

  String _importedMessage(
      String one, String many, int added, int total, bool replace) {
    if (replace || added == total) {
      return 'Imported ${_count(added, one, many)}.';
    }
    if (added == 0) return 'You already had everything in this file.';
    return 'Imported ${_count(added, one, many)}. You already had '
        '${_count(total - added, 'other', 'others')}.';
  }

  Future<void> _exportSettings() async {
    final appState = context.read<MyAppState>();
    await _save(
      _fileName('settings'),
      exportSettings(
        hiddenSystems: appState.hiddenSystems,
        notifications: appState.notifications.toBackupJson(),
      ),
      'Settings saved.',
    );
  }

  Future<void> _importSettings() async {
    final text = await _open();
    if (text == null || !mounted) return;
    final SettingsBackup backup;
    try {
      backup = parseSettingsBackup(text);
    } on BackupException catch (error) {
      _showMessage(error.message);
      return;
    }
    final appState = context.read<MyAppState>();
    final systems = backup.hiddenSystems;
    final rules = backup.notifications.rules;
    final hasCurrent = appState.hiddenSystems.isNotEmpty ||
        appState.notifications.rules.isNotEmpty;
    final replace = await _askReplace('settings', 'settings', hasCurrent);
    if (replace == null || !mounted) return;
    final addedSystems =
        appState.importHiddenSystems(systems, replace: replace);
    final addedRules = await appState.notifications
        .importBackup(backup.notifications, replace: replace);
    if (!mounted) return;

    final parts = [
      if (addedSystems > 0)
        _count(addedSystems, 'hidden system', 'hidden systems'),
      if (addedRules > 0) _count(addedRules, 'alert rule', 'alert rules'),
    ];
    if (parts.isEmpty) {
      _showMessage(systems.isEmpty && rules.isEmpty
          ? 'Imported settings.'
          : 'You already had everything in this file.');
    } else {
      _showMessage('Imported ${parts.join(' and ')}.');
    }
  }

  Future<void> _exportFavorites() async {
    final appState = context.read<MyAppState>();
    if (appState.favorites.isEmpty) {
      _showMessage('You have no favorites to export.');
      return;
    }
    await _save(
      _fileName('favorites'),
      exportFavorites(appState.favorites),
      'Favorites saved.',
    );
  }

  Future<void> _importFavorites() async {
    final text = await _open();
    if (text == null || !mounted) return;
    final List<Map<String, dynamic>> favorites;
    try {
      favorites = parseFavoritesBackup(text);
    } on BackupException catch (error) {
      _showMessage(error.message);
      return;
    }
    final appState = context.read<MyAppState>();
    final replace = await _askReplace(
        'favorites',
        _count(favorites.length, 'favorite', 'favorites'),
        appState.favorites.isNotEmpty);
    if (replace == null || !mounted) return;
    final added = appState.importFavorites(favorites, replace: replace);
    _showMessage(_importedMessage(
        'favorite', 'favorites', added, favorites.length, replace));
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    final theme = Theme.of(context);

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            text,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        );

    return ListView(
      children: [
        heading('Hidden Systems'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Some Clearcut systems aren\'t in the public list. Add one by its '
            'ID and it appears on the Systems page.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _idController,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _checking ? null : _addSystem(),
                  decoration: InputDecoration(
                    labelText: 'System ID',
                    hintText: 'e.g. very-bad',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(width: 8),
              ElevatedButton(
                onPressed: _checking ? null : _addSystem,
                child: _checking
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('Add'),
              ),
            ],
          ),
        ),
        if (appState.hiddenSystems.isEmpty)
          ListTile(
            title: Text('No hidden systems added.'),
            textColor: theme.hintColor,
          ),
        for (final system in appState.hiddenSystems)
          ListTile(
            leading: Icon(Icons.visibility_off),
            title: Text(MyAppState.hiddenSystemName(system)),
            subtitle: Text('ID: ${system['id']}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: Icon(Icons.edit),
                  onPressed: _checking ? null : () => _editSystem(system),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.delete),
                  onPressed: () => _removeSystem(system),
                ),
              ],
            ),
          ),
        Divider(height: 32),
        heading('Notifications'),
        NotificationSettingsSection(),
        Divider(height: 32),
        heading('Backup'),
        ListTile(
          leading: Icon(Icons.file_upload),
          title: Text('Export Settings'),
          subtitle: Text('Save hidden systems, notification server and alert '
              'rules to a file. Your access key isn\'t included.'),
          onTap: _exportSettings,
        ),
        ListTile(
          leading: Icon(Icons.file_download),
          title: Text('Import Settings'),
          subtitle: Text('Load hidden systems, notification server and alert '
              'rules from a file'),
          onTap: _importSettings,
        ),
        ListTile(
          leading: Icon(Icons.file_upload),
          title: Text('Export Favorites'),
          subtitle: Text('Save your favorites, in order, to a file'),
          onTap: _exportFavorites,
        ),
        ListTile(
          leading: Icon(Icons.file_download),
          title: Text('Import Favorites'),
          subtitle: Text('Load favorites from a file'),
          onTap: _importFavorites,
        ),
        SizedBox(height: 16),
      ],
    );
  }
}

/// Edits a hidden system's ID and display name. Pops `(id, name)`.
class _EditSystemDialog extends StatefulWidget {
  final Map<String, dynamic> system;
  final String? Function(String id) idProblem;

  const _EditSystemDialog({required this.system, required this.idProblem});

  @override
  State<_EditSystemDialog> createState() => _EditSystemDialogState();
}

class _EditSystemDialogState extends State<_EditSystemDialog> {
  late final _id = TextEditingController(text: widget.system['id']);
  late final _name = TextEditingController(text: widget.system['name'] ?? '');
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final id = _id.text.trim();
    final problem = widget.idProblem(id);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop((id, _name.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit Hidden System'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _id,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'System ID',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: 'Display name',
              hintText: 'Optional, shown instead of the ID',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: Text('Save')),
      ],
    );
  }
}
