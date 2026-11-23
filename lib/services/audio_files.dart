import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Where downloaded call audio is saved. Swapped out in tests.
abstract class AudioFiles {
  /// Returns false if the user cancelled.
  Future<bool> save(String fileName, Uint8List bytes, String mimeType);
}

/// Asks where to save with the system's file picker, as backups do, so the app
/// needs no storage permission and the user can pick Downloads or a cloud
/// drive.
class DeviceAudioFiles implements AudioFiles {
  const DeviceAudioFiles();

  @override
  Future<bool> save(String fileName, Uint8List bytes, String mimeType) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
    );
    return uri != null;
  }
}

/// The file name to suggest for a call's `audioFile`, which is a path such as
/// `audio/sys/1/1700000000-123.m4a`.
String audioFileName(String audioFile) {
  final name = audioFile.split('/').last;
  return name.isEmpty ? 'call-audio' : name;
}

String audioMimeType(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final extension = dot == -1 ? '' : fileName.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'm4a' || 'mp4' || 'aac' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    _ => 'application/octet-stream',
  };
}
