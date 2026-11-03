import 'package:clearcut_mobile/main.dart';
import 'package:clearcut_mobile/pages/favorites_page.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../services/call_utils.dart';
import '../services/sse_service.dart';

class ListenerPage extends StatefulWidget {
  final List<dynamic> selectedTalkgroups;
  final String currentSystem;

  ListenerPage({required this.selectedTalkgroups, required this.currentSystem});

  @override
  _ListenerPageState createState() => _ListenerPageState();
}

class _ListenerPageState extends State<ListenerPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> callData = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMoreCalls = true;
  bool loadFailed = false;
  bool loadMoreFailed = false;
  bool showFavorites = false;
  String transcriptQuery = '';
  Set<String> transcribingCalls = {};
  String? playingCallId;

  // The API has no search, so searching means paging back through history and
  // filtering here. This caps how many pages a search fetches by itself.
  static const _searchPageLimit = 12;
  int _searchPagesLeft = _searchPageLimit;

  // How close to the end of the list, in pixels, to start loading older calls.
  static const _loadMoreThreshold = 800.0;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  late final SSEService _sseService;
  AudioPlayer? _audioPlayer;
  StreamSubscription<void>? _playerCompleteSubscription;

  String get _callsUrl {
    final talkgroupIds =
        widget.selectedTalkgroups.map((tg) => tg['id']).join(',');
    return 'https://clearcutradio.app/api/v1/calls?system=${widget.currentSystem}&talkgroup=$talkgroupIds';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_loadMoreIfNeeded);

    _sseService = SSEService(
      systemName: widget.currentSystem,
      talkgroupIds: widget.selectedTalkgroups.map((tg) => tg['id']).toList(),
      onEvent: _handleStreamEvent,
      onReconnected: fetchLatestCalls,
    );

    fetchLatestCalls();
    _sseService.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sseService.stop();
    _scrollController.dispose();
    _searchController.dispose();
    _playerCompleteSubscription?.cancel();
    _audioPlayer?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Also re-fetches calls, via onReconnected, once the stream is back up.
      _sseService.reconnectNow();
    }
  }

  Future<List<Map<String, dynamic>>> _getCalls(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(apiTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('Calls returned ${response.statusCode}');
    }
    return (json.decode(response.body) as List).cast<Map<String, dynamic>>();
  }

  /// Merges the newest page of calls into the list, keeping any older pages
  /// already loaded. Returns false if the request failed.
  Future<bool> fetchLatestCalls() async {
    // Noted now, as live calls can arrive while this request is in flight.
    final newestKnown =
        callData.isEmpty ? null : callData.first['startTime'] as int?;

    try {
      final latest = await _getCalls(_callsUrl);
      if (!mounted) return false;

      // After a long gap the newest page may not reach back to what's loaded.
      // Older pages are found from the end of the list, so keeping them would
      // leave calls missing in the middle; start again from the newest instead.
      final oldestLatest =
          latest.isEmpty ? null : latest.last['startTime'] as int?;
      final hasGap = newestKnown != null &&
          oldestLatest != null &&
          oldestLatest > newestKnown;

      setState(() {
        if (hasGap) {
          callData = [];
          hasMoreCalls = true;
        }
        callData = mergeCalls(callData, latest);
        isLoading = false;
        loadFailed = false;
      });
      return true;
    } catch (error) {
      print('Error fetching calls: $error');
      if (mounted) {
        setState(() {
          isLoading = false;
          loadFailed = callData.isEmpty;
        });
      }
      return false;
    }
  }

  Future<void> fetchMoreCalls() async {
    if (isLoadingMore || callData.isEmpty) return;

    setState(() {
      isLoadingMore = true;
      loadMoreFailed = false;
    });

    try {
      final lastTimestamp = callData.last['startTime'];
      final older = await _getCalls('$_callsUrl&before_ts=$lastTimestamp');
      if (!mounted) return;
      setState(() {
        final previousCount = callData.length;
        callData = mergeCalls(callData, older);
        hasMoreCalls = callData.length > previousCount;
      });
    } catch (error) {
      print('Error fetching more calls: $error');
      if (mounted) {
        setState(() {
          loadMoreFailed = true;
        });
      }
      _showMessage("Couldn't load more calls.");
    } finally {
      if (mounted) {
        setState(() {
          isLoadingMore = false;
        });
      }
    }
  }

  /// Fetches older calls when the list is nearly scrolled to the end, or when
  /// it's too short to scroll at all. After a failure, this waits for a tap.
  void _loadMoreIfNeeded() {
    if (!mounted ||
        isLoading ||
        isLoadingMore ||
        loadFailed ||
        loadMoreFailed ||
        showFavorites ||
        !hasMoreCalls ||
        callData.isEmpty ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > _loadMoreThreshold) {
      return;
    }

    if (transcriptQuery.isNotEmpty) {
      if (_searchPagesLeft <= 0) return;
      _searchPagesLeft--;
    }
    fetchMoreCalls();
  }

  Future<void> _refreshCalls() async {
    final succeeded = await fetchLatestCalls();
    if (!succeeded) _showMessage("Couldn't refresh calls.");
  }

  void _handleStreamEvent(Map<String, dynamic> event) {
    if (!mounted) return;

    final upload = event['upload'];
    final transcript = event['transcript'];

    if (upload is Map<String, dynamic>) {
      setState(() {
        callData = mergeCalls(callData, [upload]);
      });
    } else if (transcript is Map<String, dynamic>) {
      final index =
          callData.indexWhere((call) => call['id'] == transcript['callId']);
      if (index != -1) {
        setState(() {
          callData[index]['transcript'] = transcript['text'] ?? '';
        });
      }
    }
  }

  Future<void> requestTranscription(String callId) async {
    setState(() {
      transcribingCalls.add(callId);
    });

    try {
      final response = await http
          .post(
            Uri.parse(
                'https://clearcutradio.app/api/v1/calls/transcribe?id=$callId'),
          )
          .timeout(transcribeTimeout);

      if (response.statusCode != 200) {
        throw http.ClientException(
            'Transcribe returned ${response.statusCode}');
      }
      // The transcript normally arrives over the stream, but pick it up here
      // in case the stream was reconnecting when it was sent.
      await fetchLatestCalls();
    } catch (error) {
      print('Error requesting transcription: $error');
      _showMessage("Couldn't transcribe that call.");
    } finally {
      if (mounted) {
        setState(() {
          transcribingCalls.remove(callId);
        });
      }
    }
  }

  AudioPlayer _ensureAudioPlayer() {
    var player = _audioPlayer;
    if (player == null) {
      player = _audioPlayer = AudioPlayer();
      _playerCompleteSubscription = player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            playingCallId = null;
          });
        }
      });
    }
    return player;
  }

  /// Plays a call, or stops it if it's the one already playing. Tapping a
  /// different call switches straight to it.
  Future<void> togglePlayback(Map<String, dynamic> call) async {
    final callId = call['id'] as String?;
    final audioFile = call['audioFile'] as String?;
    if (callId == null || audioFile == null) return;

    final player = _ensureAudioPlayer();
    final isStopping = playingCallId == callId;

    setState(() {
      playingCallId = isStopping ? null : callId;
    });

    try {
      if (isStopping) {
        await player.stop();
      } else {
        await player.play(UrlSource(audioUrlFor(audioFile)));
      }
    } catch (error) {
      print('Error playing/stopping audio: $error');
      if (mounted && playingCallId == callId) {
        setState(() {
          playingCallId = null;
        });
      }
      _showMessage("Couldn't play that call.");
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildCallCard(Map<String, dynamic> call) {
    final transcriptText = call['transcript'] as String;
    final callId = call['id'] as String?;
    final isTranscribing = transcribingCalls.contains(callId);

    final talkgroupName = widget.selectedTalkgroups.firstWhere(
      (tg) => tg['id'] == call['talkgroup'],
      orElse: () => {'name': 'Unknown Talkgroup'},
    )['name'];

    final startTime = call['startTime'] as int?;
    final duration = formatDuration(startTime, call['endTime'] as int?);
    final details = [
      if (startTime != null) formatTimestamp(startTime),
      if (duration.isNotEmpty) duration,
    ].join(' | ');

    return Card(
      margin: EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        title: Text(
          talkgroupName,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            transcriptText.isNotEmpty
                ? Text(transcriptText, style: TextStyle(fontSize: 14))
                : TextButton(
                    onPressed: callId != null && !isTranscribing
                        ? () => requestTranscription(callId)
                        : null, // Disable while transcribing
                    child: Text(
                        isTranscribing ? 'Transcribing...' : 'Transcribe Call'),
                  ),
            SizedBox(height: 10),
            Text(
              details,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        trailing: IconButton(
          icon: Icon(playingCallId != null && playingCallId == callId
              ? Icons.stop
              : Icons.play_arrow),
          onPressed: () => togglePlayback(call),
        ),
      ),
    );
  }

  Widget _buildListFooter() {
    Widget? status;
    Widget? button;

    if (isLoadingMore) {
      status = SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (callData.isEmpty) {
      status = Text('No calls found.');
    } else if (!hasMoreCalls) {
      status = Text('No older calls.');
    } else if (transcriptQuery.isNotEmpty && _searchPagesLeft <= 0) {
      status = Text(
        'Searched back to ${formatTimestamp(callData.last['startTime'])}',
        textAlign: TextAlign.center,
      );
      button = ElevatedButton(
        onPressed: () {
          setState(() {
            _searchPagesLeft = _searchPageLimit;
          });
        },
        child: Text('Search Further Back'),
      );
    } else {
      button = ElevatedButton(
        onPressed: fetchMoreCalls,
        child: Text('Load More Calls'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status != null) status,
            if (status != null && button != null) SizedBox(height: 8),
            if (button != null) button,
          ],
        ),
      ),
    );
  }

  Widget _buildCallList() {
    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load calls."),
            SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  isLoading = true;
                  loadFailed = false;
                });
                fetchLatestCalls();
              },
              child: Text('Retry'),
            ),
          ],
        ),
      );
    }

    final query = transcriptQuery.toLowerCase();
    final visibleCalls = callData
        .where((call) =>
            (call['transcript'] as String).toLowerCase().contains(query))
        .toList();

    return RefreshIndicator(
      onRefresh: _refreshCalls,
      child: ListView.builder(
        controller: _scrollController,
        physics: AlwaysScrollableScrollPhysics(),
        itemCount: visibleCalls.length + 1, // Add 1 for the footer
        itemBuilder: (context, index) {
          return index == visibleCalls.length
              ? _buildListFooter()
              : _buildCallCard(visibleCalls[index]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isFavorite = context
        .watch<MyAppState>()
        .isFavorite(widget.currentSystem, widget.selectedTalkgroups);

    // Checked after every build, since a search or a short page can leave the
    // list without enough calls to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMoreIfNeeded());

    return Scaffold(
      appBar: AppBar(
        title: Text(showFavorites ? "Favorites" : "Stream"),
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
          // Opening a favorite replaces this page, so its stream and audio stop.
          ? FavoritesPage(replacePageOnOpen: true)
          : Padding(
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
                      labelText: 'Search Calls',
                      hintText: 'Enter keyword',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    controller: _searchController,
                    onChanged: (value) {
                      setState(() {
                        transcriptQuery = value;
                        _searchPagesLeft = _searchPageLimit;
                      });
                    },
                  ),
                  SizedBox(height: 16),
                  Expanded(child: _buildCallList()),
                  if (!isFavorite)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 15),
                        child: ElevatedButton(
                          onPressed: () {
                            context.read<MyAppState>().addFavorite(
                                widget.currentSystem,
                                widget.selectedTalkgroups);
                            _showMessage('Added to favorites!');
                          },
                          child: Text('Add Talkgroup(s) to Favorites'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
