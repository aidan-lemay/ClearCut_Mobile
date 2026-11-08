import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/services/notifications.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> _confirm(
    BuildContext context, String title, String message, String action) async {
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

/// The Notifications part of the Settings page.
class NotificationSettingsSection extends StatefulWidget {
  const NotificationSettingsSection({super.key});

  @override
  State<NotificationSettingsSection> createState() =>
      _NotificationSettingsSectionState();
}

class _NotificationSettingsSectionState
    extends State<NotificationSettingsSection> {
  final _address = TextEditingController();
  final _port = TextEditingController();
  final _key = TextEditingController();
  bool _editingServer = false;
  bool _showKey = false;
  bool _busy = false;
  String? _connectError;

  NotificationController get _controller =>
      context.read<MyAppState>().notifications;

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  void _startEditing(NotificationController controller) {
    _address.text = controller.address;
    _port.text = controller.port?.toString() ?? '';
    _key.text = controller.key;
    setState(() {
      _editingServer = true;
      _connectError = null;
    });
  }

  Future<void> _connect() async {
    final portText = _port.text.trim();
    final port = portText.isEmpty ? null : int.tryParse(portText);
    if (portText.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      setState(() => _connectError = 'The port must be a number from 1 to '
          '65535, or left empty.');
      return;
    }
    setState(() {
      _busy = true;
      _connectError = null;
    });
    final error = await _controller.connect(_address.text, port, _key.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _connectError = error;
      if (error == null) _editingServer = false;
    });
    if (error == null) _showMessage(context, 'Connected to the relay.');
  }

  Future<void> _pause() async {
    const choices = <(String, Duration?)>[
      ('1 hour', Duration(hours: 1)),
      ('4 hours', Duration(hours: 4)),
      ('8 hours', Duration(hours: 8)),
      ('Until I resume', null),
    ];
    final choice = await showDialog<(String, Duration?)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Pause Notifications'),
        children: [
          for (final choice in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(choice),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(choice.$1),
              ),
            ),
        ],
      ),
    );
    if (choice != null) await _controller.pause(choice.$2);
  }

  Future<void> _sendTest() async {
    final error = await _controller.sendTest();
    if (mounted) {
      _showMessage(context, error ?? 'Test sent. It should arrive shortly.');
    }
  }

  Future<void> _unsubscribe() async {
    final confirmed = await _confirm(
      context,
      'Unsubscribe?',
      'This phone stops getting notifications and is removed from the relay. '
          'Your rules are kept, in case you connect again.',
      'Unsubscribe',
    );
    if (!confirmed) return;
    final warning = await _controller.unsubscribe();
    if (mounted) _showMessage(context, warning ?? 'Unsubscribed.');
  }

  String _pausedText(BuildContext context, NotificationController controller) {
    final until = controller.pausedUntil;
    if (until == null) return 'Paused until you resume';
    final time = TimeOfDay.fromDateTime(until).format(context);
    final now = DateTime.now();
    final sameDay = until.year == now.year &&
        until.month == now.month &&
        until.day == now.day;
    return sameDay
        ? 'Paused until $time'
        : 'Paused until ${until.month}/${until.day} $time';
  }

  void _openRule([AlertRule? rule]) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => RuleEditorPage(rule: rule),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MyAppState>().notifications;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.push.available) {
          return ListTile(
            leading: Icon(Icons.notifications_off),
            title: Text('Not available in this copy of the app'),
            subtitle: Text('It was built without push support. See the README '
                'for how to add it.'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: controller.subscribed && !_editingServer
              ? _connected(context, controller)
              : _serverForm(context, controller),
        );
      },
    );
  }

  List<Widget> _serverForm(
      BuildContext context, NotificationController controller) {
    if (!_editingServer && _address.text.isEmpty && _key.text.isEmpty) {
      _address.text = controller.address;
      _port.text = controller.port?.toString() ?? '';
      _key.text = controller.key;
    }
    final plainHttp =
        relayBaseUri(_address.text, int.tryParse(_port.text))?.scheme == 'http';
    final theme = Theme.of(context);

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text('Get alerts for calls and transcripts from a Clearcut '
            'relay. Ask whoever runs it for an access key.'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: TextField(
          controller: _address,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Server address',
            hintText: 'relay.example.com or 192.168.1.10',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: TextField(
          controller: _port,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Port',
            hintText: 'Optional',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: TextField(
          controller: _key,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: !_showKey,
          decoration: InputDecoration(
            labelText: 'Access key',
            border: OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Hide key' : 'Show key',
              icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
      ),
      if (plainHttp)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'With http:// your access key is sent unencrypted. Only use it on '
            'your own network.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      if (_connectError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(_connectError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_editingServer)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _editingServer = false;
                          _connectError = null;
                        }),
                child: Text('Cancel'),
              ),
            SizedBox(width: 8),
            ElevatedButton(
              onPressed: _busy ? null : _connect,
              child: _busy
                  ? SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Connect'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _connected(
      BuildContext context, NotificationController controller) {
    final theme = Theme.of(context);
    final base = relayBaseUri(controller.address, controller.port);
    final status = controller.status;
    final subtitle = [
      if (status != null && status.keyName.isNotEmpty) 'Key: ${status.keyName}',
      if (controller.syncing) 'Updating…',
    ].join(' · ');

    return [
      ListTile(
        leading: Icon(Icons.cloud_done),
        title: Text('Connected to ${base?.host ?? controller.address}'
            '${base != null && base.hasPort ? ':${base.port}' : ''}'),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: IconButton(
          tooltip: 'Change server',
          icon: Icon(Icons.edit),
          onPressed: () => _startEditing(controller),
        ),
      ),
      if (controller.syncError != null)
        ListTile(
          leading: Icon(Icons.sync_problem, color: theme.colorScheme.error),
          title: Text('The relay isn\'t up to date'),
          subtitle: Text(controller.syncError!),
          trailing: TextButton(
            onPressed: controller.syncing ? null : controller.sync,
            child: Text('Retry'),
          ),
        ),
      if (status != null && !status.canPush)
        ListTile(
          leading: Icon(Icons.warning_amber, color: theme.colorScheme.error),
          title: Text('The relay can\'t send notifications yet'),
          subtitle: Text('It has no Firebase key set up. Ask whoever runs it.'),
        ),
      if (controller.isPaused)
        ListTile(
          leading: Icon(Icons.pause_circle),
          title: Text(_pausedText(context, controller)),
          trailing: TextButton(
            onPressed: controller.resume,
            child: Text('Resume'),
          ),
        )
      else
        ListTile(
          leading: Icon(Icons.pause),
          title: Text('Pause Notifications'),
          subtitle: Text('Stop alerts for a while'),
          onTap: _pause,
        ),
      ListTile(
        leading: Icon(Icons.notifications_active),
        title: Text('Send Test Notification'),
        onTap: _sendTest,
      ),
      ListTile(
        leading: Icon(Icons.notifications_off),
        title: Text('Unsubscribe'),
        subtitle: Text('Stop notifications and leave the relay'),
        onTap: _unsubscribe,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Alert Rules', style: theme.textTheme.titleSmall),
      ),
      if (controller.rules.isEmpty)
        ListTile(
          title: Text('No rules yet. Add one to choose which calls notify '
              'you.'),
          textColor: theme.hintColor,
        ),
      for (final rule in controller.rules)
        ListTile(
          title: Text(rule.name),
          subtitle: Text(rule.summary),
          onTap: () => _openRule(rule),
          trailing: Switch(
            value: rule.enabled,
            onChanged: (enabled) =>
                controller.saveRule(rule.copyWith(enabled: enabled)),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton.icon(
            onPressed: () => _openRule(),
            icon: Icon(Icons.add),
            label: Text('Add Rule'),
          ),
        ),
      ),
    ];
  }
}

/// Creates or edits one alert rule.
class RuleEditorPage extends StatefulWidget {
  final AlertRule? rule;

  const RuleEditorPage({super.key, this.rule});

  @override
  State<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<RuleEditorPage> {
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _keywords =
      TextEditingController(text: widget.rule?.keywords.join(', ') ?? '');
  final _search = TextEditingController();

  String? _systemId;
  String _systemName = '';
  late AlertMode _mode = widget.rule?.mode ?? AlertMode.keywords;

  /// Selected talkgroups by ID, kept in the order they were picked.
  final _selected = <int, Map<String, dynamic>>{};
  Future<List<dynamic>>? _talkgroups;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    if (rule != null) {
      _systemId = rule.systemId;
      _systemName = rule.systemName;
      for (final tg in rule.talkgroups) {
        _selected[tg['id']] = tg;
      }
      _loadTalkgroups();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _keywords.dispose();
    _search.dispose();
    super.dispose();
  }

  void _loadTalkgroups() {
    final id = _systemId;
    if (id != null) {
      _talkgroups = context.read<MyAppState>().fetchTalkgroups(id);
    }
  }

  void _chooseSystem(Map<String, dynamic> system) {
    if (system['id'] == _systemId) return;
    setState(() {
      _systemId = system['id'];
      _systemName = system['name'];
      _selected.clear();
      _loadTalkgroups();
    });
  }

  void _toggle(Map<String, dynamic> tg, bool selected) {
    setState(() {
      if (selected) {
        _selected[tg['id']] = {'id': tg['id'], 'name': tg['name']};
      } else {
        _selected.remove(tg['id']);
      }
    });
  }

  Future<void> _save() async {
    final keywords = parseKeywords(_keywords.text);
    String? problem;
    if (_systemId == null) {
      problem = 'Choose a system.';
    } else if (_selected.isEmpty) {
      problem = 'Choose at least one talkgroup.';
    } else if (_mode == AlertMode.keywords && keywords.isEmpty) {
      problem = 'Enter at least one keyword.';
    }
    if (problem != null) {
      _showMessage(context, problem);
      return;
    }

    var name = _name.text.trim();
    if (name.isEmpty) {
      name = _selected.values.map((tg) => tg['name']).join(', ');
    }
    if (name.length > 100) name = '${name.substring(0, 99)}…';

    final rule = AlertRule(
      id: widget.rule?.id,
      name: name,
      enabled: widget.rule?.enabled ?? true,
      systemId: _systemId!,
      systemName: _systemName,
      talkgroups: _selected.values.toList(),
      mode: _mode,
      keywords: _mode == AlertMode.keywords ? keywords : [],
    );
    final controller = context.read<MyAppState>().notifications;
    final navigator = Navigator.of(context);
    await controller.saveRule(rule);
    navigator.pop();
  }

  Future<void> _delete() async {
    final rule = widget.rule!;
    final confirmed =
        await _confirm(context, 'Delete ${rule.name}?', '', 'Delete');
    if (!confirmed || !mounted) return;
    final controller = context.read<MyAppState>().notifications;
    final navigator = Navigator.of(context);
    await controller.deleteRule(rule.id);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<MyAppState>();
    final systems = [...appState.allSystems];
    if (_systemId != null && !systems.any((s) => s['id'] == _systemId)) {
      systems.add({'id': _systemId, 'name': _systemName});
    }
    final favorites = appState.favorites
        .where((favorite) => favorite['systemId'] == _systemId)
        .toList();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rule == null ? 'New Rule' : 'Edit Rule'),
        actions: [
          if (widget.rule != null)
            IconButton(
              tooltip: 'Delete rule',
              icon: Icon(Icons.delete),
              onPressed: _delete,
            ),
          TextButton(onPressed: _save, child: Text('Save')),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'Optional, defaults to the talkgroup names',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              Text('Notify me about', style: theme.textTheme.titleSmall),
              SizedBox(height: 8),
              SegmentedButton<AlertMode>(
                segments: [
                  ButtonSegment(
                      value: AlertMode.keywords, label: Text('Keywords')),
                  ButtonSegment(
                      value: AlertMode.transcripts, label: Text('Transcripts')),
                  ButtonSegment(
                      value: AlertMode.all, label: Text('Every call')),
                ],
                selected: {_mode},
                onSelectionChanged: (modes) =>
                    setState(() => _mode = modes.single),
              ),
              SizedBox(height: 8),
              Text(switch (_mode) {
                AlertMode.keywords =>
                  'Transcripts that contain one of your keywords.',
                AlertMode.transcripts => 'Every call once it\'s transcribed.',
                AlertMode.all => 'Every call as it comes in, updated with its '
                    'transcript if it gets one.',
              }),
              if (_mode == AlertMode.keywords) ...[
                SizedBox(height: 12),
                TextField(
                  controller: _keywords,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Keywords',
                    hintText: 'fire, shots fired, mva',
                    helperText: 'Separate with commas. Matches whole words; '
                        'end one with * to match word starts, like fire*.',
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _systemId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'System',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final system in systems)
                    DropdownMenuItem(
                      value: system['id'] as String,
                      child: Text(system['name'] as String,
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) => _chooseSystem(
                    systems.firstWhere((system) => system['id'] == id)),
              ),
              if (_systemId != null) ...[
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text('Talkgroups (${_selected.length} chosen)',
                          style: theme.textTheme.titleSmall),
                    ),
                    if (favorites.isNotEmpty)
                      PopupMenuButton<Map<String, dynamic>>(
                        tooltip: 'Add from a favorite',
                        onSelected: (favorite) => setState(() {
                          for (final tg in favorite['talkgroups']) {
                            _selected[tg['id']] = {
                              'id': tg['id'],
                              'name': tg['name']
                            };
                          }
                        }),
                        itemBuilder: (context) => [
                          for (final favorite in favorites)
                            PopupMenuItem(
                              value: favorite,
                              child: Text(
                                  favorite['talkgroups']
                                      .map((tg) => tg['name'])
                                      .join(', '),
                                  overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.favorite, size: 18),
                              SizedBox(width: 4),
                              Text('From favorite'),
                            ],
                          ),
                        ),
                      ),
                    if (_selected.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(_selected.clear),
                        child: Text('Clear'),
                      ),
                  ],
                ),
                SizedBox(height: 8),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Search talkgroups',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ]),
          ),
          if (_systemId != null) _talkgroupList(theme),
        ],
      ),
    );
  }

  Widget _talkgroupList(ThemeData theme) {
    return FutureBuilder<List<dynamic>>(
      future: _talkgroups,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: Column(
              children: [
                Text('Couldn\'t load talkgroups.'),
                TextButton(
                  onPressed: () => setState(_loadTalkgroups),
                  child: Text('Retry'),
                ),
              ],
            ),
          );
        }

        final all = snapshot.data ?? [];
        final query = _search.text.trim().toLowerCase();
        final shown = all.where((tg) {
          if (query.isEmpty) return true;
          return '${tg['name']} ${tg['description'] ?? ''} ${tg['id']}'
              .toLowerCase()
              .contains(query);
        }).toList();

        final untranscribed = all
            .where((tg) =>
                _selected.containsKey(tg['id']) && tg['transcribe'] != true)
            .length;

        return SliverMainAxisGroup(slivers: [
          if (_mode != AlertMode.all && untranscribed > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  untranscribed == 1
                      ? '1 chosen talkgroup isn\'t transcribed, so it will '
                          'never match. Use Every call for it.'
                      : '$untranscribed chosen talkgroups aren\'t transcribed, '
                          'so they will never match. Use Every call for them.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (context, index) {
              final tg = shown[index];
              return CheckboxListTile(
                value: _selected.containsKey(tg['id']),
                onChanged: (value) => _toggle(tg, value ?? false),
                title: Text(tg['name']),
                subtitle: Text(tg['description'] ?? ''),
                secondary: tg['transcribe'] == true
                    ? Tooltip(
                        message: 'Transcribed',
                        child: Icon(Icons.check_circle, color: Colors.green),
                      )
                    : null,
              );
            },
          ),
          SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]);
      },
    );
  }
}
