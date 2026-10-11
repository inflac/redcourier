import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:redcourier/logger.dart';

import 'crypto.dart';
import 'proxy.dart';
import 'app_notifier.dart';

class UploadStatus {
  final String statusText;
  // 0.0 to 1.0 (Progress of the current ZIP upload/processing)
  final double progress;

  UploadStatus(this.statusText, {this.progress = 0.0});
}

class UploadManager {
  List<XFile> selectedFiles = [];

  // Number of selected files
  int get fileCount => selectedFiles.length;
  // Names of selected files
  List<String> get fileNames => selectedFiles.map((f) => f.name).toList();

  // NEW: For communicating status to the UI
  final _statusController = StreamController<UploadStatus>.broadcast();
  Stream<UploadStatus> get statusStream => _statusController.stream;

  void dispose() {
    _statusController.close();
  }

  // HELPER FUNCTION to send updates
  void _updateStatus(String text, {double progress = 0.0}) {
    _statusController.add(UploadStatus(text, progress: progress));
  }

  // Select files (works on Android & Desktop)
  Future<void> chooseFiles() async {

    // Only Android needs withReadStream, Desktop can use openFiles
    if (Platform.isAndroid) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,      // Do not load entire file into RAM
        withReadStream: true, // Use stream instead of entire file
      );

      if (result == null) return; // User cancelled
      selectedFiles = result.files.map((f) => XFile(f.path!)).toList();

    } else {
      // Desktop & other platforms
      final files = await openFiles(
        acceptedTypeGroups: [XTypeGroup(label: 'All', extensions: ['*'])],
      );
      selectedFiles = files;
    }
  }

  /// Create DownloadURI (DeepLink)
  String createDeepLink(String downloadID, String password) {
    final encodedPassword = Uri.encodeComponent(base64UrlEncode(utf8.encode(password)));
    final encodedDownloadID = Uri.encodeComponent(downloadID);
    return 'redcourier://download?downloadID=$encodedDownloadID&password=$encodedPassword';
  }

  /// Create encrypted ZIPs and return list of zip paths + password
  Future<Map<String, dynamic>?> createZips() async {
    if (selectedFiles.isEmpty) return null;

    // Convert XFile paths to transferable File objects for the Isolate
    List<File> files = selectedFiles.map((x) => File(x.path)).toList();

    try {
      _updateStatus("Encrypting files...");

      // CRITICAL: Call the Isolate-safe encryption function
      final result = await FileCryptoManager.encryptFilesSafe(files);

      final zipPaths = result['zipPaths'] as List<String>?;
      final password = result['password'] as String?;
      final tempDirPath = result['tempDirPath'] as String?;

      if (zipPaths == null || zipPaths.isEmpty || password == null || tempDirPath == null) {
        AppNotifier.showError("Failed to create ZIP(s): missing path(s) or password.");
        if (tempDirPath != null) await Directory(tempDirPath).delete(recursive: true);
        return null;
      }

      // Compute SHA256 hash for each ZIP in chunks (This is typically quick on temp files)
      _updateStatus("Calculating file integrity (SHA256)...");
      final zipHashes = <String>[];
      for (final path in zipPaths) {
        final file = File(path);
        final hash = await _chunkedSha256(file);
        zipHashes.add(hash);
      }

      return {
        'zipPaths': zipPaths,
        'password': password,
        'hashes': zipHashes,
        'tempDirPath': tempDirPath, // Return temp directory path for cleanup later
      };
    } catch (e) {
      AppNotifier.showError("Error creating ZIP(s): $e");
      return null;
    }
  }

  /// Compute SHA256 hash of a file in chunks (memory safe)
  Future<String> _chunkedSha256(File file) async {
    final accumulator = AccumulatorSink<Digest>();
    final sink = sha256.startChunkedConversion(accumulator);

    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }

    sink.close();
    return accumulator.events.single.toString();
  }

  /// Upload a ZIP to filebin.net (non-streaming, memory-safe)
  Future<String?> uploadToFilebin(String zipPath, {int partIndex = 1, int totalParts = 1}) async {
    const chunkSize = 1024 * 1024; // 1 MB
    int uploadedBytes = 0;

    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      AppNotifier.showError("File not found: $zipPath");
      return null;
    }

    // Prepare zip for upload and construct upload uri
    final totalBytes = await zipFile.length();
    final binName = FileCryptoManager.generateUrlSafeString(16);
    final fileName = zipFile.uri.pathSegments.last;
    final uri = Uri.parse('https://filebin.net/$binName/$fileName');

    // Open Zip
    final raf = await zipFile.open();
    // Create HTTP client
    final client = ProxyConfig.createHttpClient();

    _updateStatus("Uploading part $partIndex/$totalParts...");
    // Upload
    try {
      // Create http POST request
      final request = await client.postUrl(uri);

      // Set proper headers (important: include Content-Length)
      request.headers.contentType = ContentType.binary;
      request.headers.set('Content-Length', totalBytes.toString());

      // Read chunk and write it to the socket
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;

        request.add(chunk);

        uploadedBytes += chunk.length;
        final progress = uploadedBytes / totalBytes;
        _updateStatus("Uploading part $partIndex/$totalParts...", progress: progress);
      }
      _updateStatus("Uploading part $partIndex/$totalParts...");
      await raf.close();

      final response = await request.close();
      client.close();

      if (response.statusCode == 201) {
        _updateStatus("Upload part $partIndex/$totalParts complete.", progress: 1.0);
        return uri.toString();
      } else {
        AppLogger.error("Upload error: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      await raf.close();
      client.close(force: true);
      AppLogger.error("Upload error: $e");
      return null;
    }
  }


  /// Upload workflow: create ZIP(s) + upload each + generate downloadID & deep link
  Future<Map<String, dynamic>?> uploadFiles() async {
    final zipResult = await createZips();
    if (zipResult == null) return null;

    final zipPaths = zipResult['zipPaths'] as List<String>;
    final password = zipResult['password'] as String;
    final zipHashes = zipResult['hashes'] as List<String>;
    final tempDirPath = zipResult['tempDirPath'] as String; // NEW: Get temporary directory path

    final uploadedLinks = <String>[];
    final totalParts = zipPaths.length;

    // Upload each ZIP separately
    for (int i = 0; i < totalParts; i++) {
      final zipPath = zipPaths[i];
      final partIndex = i + 1;

      final link = await uploadToFilebin(
          zipPath,
          partIndex: partIndex,
          totalParts: totalParts
      );
      if (link == null) {
        AppNotifier.showError("Failed to upload one of the ZIPs.");
        // CRITICAL: Cleanup the entire temp folder on failure
        await Directory(tempDirPath).delete(recursive: true);
        return null;
      }
      uploadedLinks.add(link);

      // NOTE: We don't need to manually delete individual ZIPs here,
      // as they are located inside the tempDirPath which will be deleted later.
    }

    // Combine hashes and links into a single downloadID
    final combinedList = [
      for (int i = 0; i < uploadedLinks.length; i++)
        'hash=${zipHashes[i]}&url=${uploadedLinks[i]}'
    ];
    final downloadID = base64UrlEncode(utf8.encode(combinedList.join(',')));
    final downloadURI = createDeepLink(downloadID, password);

    // CRITICAL: Cleanup the main temporary directory
    try {
      await Directory(tempDirPath).delete(recursive: true);
    } catch (e) {
      AppLogger.error('Error cleaning up temporary directory $tempDirPath: $e');
      AppNotifier.showError("Error cleaning up temporary directory.");
    }

    // FINAL: Final status update (progress: 1.0)
    _updateStatus("Finalizing download link...", progress: 1.0);
    AppNotifier.showSuccess("Files uploaded successfully!");

    return {
      'password': password,
      'downloadID': downloadID,
      'downloadURI': downloadURI,
      'links': uploadedLinks,
    };
  }
}