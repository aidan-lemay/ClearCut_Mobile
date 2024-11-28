import 'package:clearcut_mobile/main.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../services/sse_service.dart';

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
  bool isLoadingMore = false;
  String transcriptQuery = '';
  late SSEService _sseService;
  late AudioPlayer _audioPlayer;

  @override
  void initState() {
    super.initState();
    initializeAudioPlayer();
    fetchInitialCalls();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void initializeAudioPlayer() {
    _audioPlayer = AudioPlayer();
  }

  Future<void> fetchInitialCalls() async {
    try {
      final systemId = widget.currentSystem;
      final talkgroupIds =
          widget.selectedTalkgroups.map((tg) => tg['id']).join(',');

      final response = await http.get(Uri.parse(
          'https://clearcutradio.app/api/v1/calls?system=$systemId&talkgroup=$talkgroupIds'));

      if (response.statusCode == 200) {
        final initialData = json.decode(response.body);

        initialData.forEach((call) {
          if (call['transcript'] != null && call['transcript'] is Map) {
            call['transcript'] = call['transcript']['text'] ??
                ''; // Map transcript object to string
          } else if (call['transcript'] == null) {
            call['transcript'] =
                ''; // If transcript is null, set it to an empty string
          }
        });

        setState(() {
          callData = initialData;
          isLoading = false;
        });

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

  Future<void> fetchMoreCalls() async {
    if (isLoadingMore || callData.isEmpty) return;

    setState(() {
      isLoadingMore = true;
    });

    try {
      final systemId = widget.currentSystem;
      final talkgroupIds =
          widget.selectedTalkgroups.map((tg) => tg['id']).join(',');
      final lastTimestamp = callData.last['startTime'];

      final response = await http.get(Uri.parse(
          'https://clearcutradio.app/api/v1/calls?system=$systemId&talkgroup=$talkgroupIds&before_ts=$lastTimestamp'));

      if (response.statusCode == 200) {
        final newCalls = json.decode(response.body);

        newCalls.forEach((call) {
          if (call['transcript'] != null && call['transcript'] is Map) {
            call['transcript'] = call['transcript']['text'] ??
                ''; // Map transcript object to string
          } else if (call['transcript'] == null) {
            call['transcript'] =
                ''; // If transcript is null, set it to an empty string
          }
        });

        setState(() {
          callData.addAll(newCalls);
          isLoadingMore = false;
        });
      } else {
        setState(() {
          isLoadingMore = false;
        });
        throw Exception('Failed to load more call data');
      }
    } catch (error) {
      setState(() {
        isLoadingMore = false;
      });
      print('Error fetching more calls: $error');
    }
  }

  void subscribeToSSE() {
    final talkgroupIds =
        widget.selectedTalkgroups.map((tg) => tg['id']).toList();

    _sseService = SSEService(
      systemName: widget.currentSystem,
      talkgroupIds: talkgroupIds,
    );

    _sseService.startListening((eventData) {
      if (eventData.containsKey('upload')) {
        handleNewCall(eventData['upload']);
      } else if (eventData.containsKey('transcript')) {
        handleTranscript(eventData['transcript']);
      }
    });
  }

  void handleNewCall(Map<String, dynamic> newCall) {
    setState(() {
      if (newCall['transcript'] == null) {
        newCall['transcript'] = ''; // If there's no transcript, set it to empty
      }
      callData.insert(0, newCall);
    });
  }

  void handleTranscript(Map<String, dynamic> newTranscript) {
    final callId = newTranscript['callId'];
    final index = callData.indexWhere((call) => call['id'] == callId);

    if (index != -1) {
      setState(() {
        callData[index]['transcript'] = newTranscript['text'];
      });
    } else {
      print('Transcript for non-existent call: $callId');
    }
  }

  void playAudio(String audioFile) async {
    const baseUrl = 'https://audio.clearcutradio.app/';

    if (audioFile.startsWith('audio/')) {
      audioFile = audioFile.replaceFirst('audio/', '');
    }

    final fullUrl = Uri.parse('$baseUrl$audioFile');

    try {
      if (_audioPlayer.state == PlayerState.playing) {
        // Stop playback if already playing
        await _audioPlayer.stop();
        print('Audio stopped.');
      } else {
        // Start playback
        print('Playing audio from: $fullUrl');
        await _audioPlayer.play(UrlSource(fullUrl.toString()));
        print('Playing audio successfully.');
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
                  itemCount: callData.length + 1, // Add 1 for the button
                  itemBuilder: (context, index) {
                    if (index == callData.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16.0),
                        child: Center(
                          child: ElevatedButton(
                            onPressed: fetchMoreCalls,
                            child: isLoadingMore
                                ? CircularProgressIndicator()
                                : Text('Load More Calls'),
                          ),
                        ),
                      );
                    }

                    final call = callData[index];
                    final transcript =
                        call['transcript'] ?? 'No transcript available';

                    final transcriptText =
                        transcript is String ? transcript : '';

                    if (!transcriptText
                        .toLowerCase()
                        .contains(transcriptQuery.toLowerCase())) {
                      return SizedBox.shrink();
                    }

                    final talkgroupName = widget.selectedTalkgroups.firstWhere(
                      (tg) => tg['id'] == call['talkgroup'],
                      orElse: () => {'name': 'Unknown Talkgroup'},
                    )['name'];

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
                            Text(transcriptText,
                                style: TextStyle(fontSize: 14)),
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
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 15),
                child: ElevatedButton(
                  onPressed: () {
                    var appState = context.read<MyAppState>();
                    appState.addFavorite(
                        widget.currentSystem, widget.selectedTalkgroups);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added to favorites!')),
                    );
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
