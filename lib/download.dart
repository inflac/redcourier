import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'crypto.dart'; // FileCryptoManager
import 'app_notifier.dart'; // AppNotifier
import 'proxy.dart';
import 'logger.dart';

class DownloadStatus {
  final String statusText;
  final double? progress; // Nullable: null = indeterminate phase
  DownloadStatus(this.statusText, {this.progress = 0.0});
}

class DownloadManager {
  final _statusController = StreamController<DownloadStatus>.broadcast();
  Stream<DownloadStatus> get statusStream => _statusController.stream;

  void dispose() => _statusController.close();

  /// Helper to send progress updates
  void _updateStatus(String text, {double? progress = 0.0}) {
    final progressText =
    progress != null ? ' (${(progress * 100).toStringAsFixed(0)}%)' : ' (Processing)';
    AppLogger.debug('[DL_STATUS] $text$progressText');
    _statusController.add(DownloadStatus(text, progress: progress));
  }

  /// Decode and parse the downloadID (base64url encoded)
  static List<Map<String, String>> parseDownloadID(String downloadID) {
    final decoded = utf8.decode(base64Url.decode(downloadID));
    final zipInfos = decoded.split(',');
    return zipInfos.map((entry) {
      final parts = entry.split('&');
      final hash = parts.firstWhere((e) => e.startsWith('hash=')).substring(5);
      final url = parts.firstWhere((e) => e.startsWith('url=')).substring(4);
      return {'hash': hash, 'url': url};
    }).toList();
  }

  /// Main download + decrypt flow
  Future<String?> downloadAndDecrypt(String downloadID, String password) async {
    const double overallDownloadWeight = 0.8;
    const double overallDecryptWeight = 0.1;
    const double initialSetupWeight = 0.1;

    Directory? outputDir;

    try {
      late List zipInfos;

      // --- Setup phase ---
      _updateStatus("Starting setup...", progress: 0.0);
      AppLogger.debug('Parsing downloadID...');

      try {
        zipInfos = parseDownloadID(downloadID);
        if (zipInfos.isEmpty) {
          AppLogger.warn('Parsed zipInfos is empty.');
          AppNotifier.showError("Invalid downloadID or empty ZIP list.");
          return null;
        }
      } on FormatException {
        AppNotifier.showError("Invalid download ID or corrupted link.");
        return null;
      }

      // Request permissions (Android)
      if (Platform.isAndroid) {
        try {
          await _requestMediaPermission();
        } catch (e) {
          AppLogger.error('Permission denied: $e');
          AppNotifier.showError("Media permissions denied.");
          return null;
        }
      }

      // Determine output directory
      Directory baseDir;
      if (Platform.isAndroid) {
        baseDir = Directory('/storage/emulated/0/Download/RedCourier');
      } else {
        final downloadsDir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        baseDir = Directory('${downloadsDir.path}/RedCourier');
      }
      if (!await baseDir.exists()) await baseDir.create(recursive: true);

      // Create unique session dir
      final rand = Random.secure();
      final randStr = List.generate(6, (_) => rand.nextInt(10)).join();
      outputDir = Directory('${baseDir.path}/$randStr');
      if (!await outputDir.exists()) await outputDir.create(recursive: true);

      final totalLinks = zipInfos.length;
      final downloadWeightPerPart = overallDownloadWeight / totalLinks;
      final decryptWeightPerPart = overallDecryptWeight / totalLinks;
      double currentOverallProgress = initialSetupWeight;

      _updateStatus("Setup complete. Starting downloads.", progress: currentOverallProgress);

      final downloadedZipPaths = <String>[];

      // --- Download + Decrypt per part ---
      for (int i = 0; i < totalLinks; i++) {
        final zipInfo = zipInfos[i];
        final url = zipInfo['url']!;
        final expectedHash = zipInfo['hash']!;
        final partIndex = i + 1;

        _updateStatus("Preparing download part $partIndex/$totalLinks...",
            progress: currentOverallProgress);
        AppLogger.debug('Starting download for part $partIndex: $url');

        final tempZipPath = "${outputDir.path}/part_$partIndex.zip";

        final (actualHash, zipPath) = await _streamAndHashDownload(
          url,
          tempZipPath,
          expectedHash,
              (partProgress) {
            final overallProgress =
                currentOverallProgress + (partProgress * downloadWeightPerPart);
            _updateStatus("Downloading part $partIndex/$totalLinks...",
                progress: overallProgress);
          },
        );

        if (actualHash == null) return null;

        if (actualHash != expectedHash) {
          AppLogger.warn('Hash mismatch: expected=$expectedHash, got=$actualHash');
          AppNotifier.showError("Hash mismatch for part $partIndex. Download may be corrupted.");
          await File(zipPath).delete();
          return null;
        }

        currentOverallProgress += downloadWeightPerPart;
        _updateStatus("Download part $partIndex complete.", progress: currentOverallProgress);
        downloadedZipPaths.add(zipPath);

        // --- Decryption ---
        try {
          _updateStatus("Decrypting part $partIndex/$totalLinks...", progress: null);
          AppLogger.debug('Starting decryption for part $partIndex...');

          await FileCryptoManager.decryptFilesSafe(
            [zipPath],
            password,
            outputDir.path,
          );

          currentOverallProgress += decryptWeightPerPart;
          _updateStatus("Decryption part $partIndex complete.",
              progress: currentOverallProgress);
        } catch (e) {
          AppLogger.error('Decryption failed for part $partIndex: $e');
          AppNotifier.showError("Decryption failed: Invalid password or corrupted files.");
          if (await outputDir.exists()) await outputDir.delete(recursive: true);
          return null;
        } finally {
          try {
            await File(zipPath).delete();
          } catch (_) {}
        }
      }

      // --- Finalization ---
      _updateStatus("Download and decryption complete!", progress: 1.0);
      AppNotifier.showSuccess("Download and decryption completed.");
      AppLogger.info('All downloads and decryptions complete. Output: ${outputDir.path}');
      return outputDir.path;
    } catch (e) {
      AppLogger.error('Download failed: $e');
      _updateStatus("Download failed: ${e.toString()}", progress: 0.0);
      AppNotifier.showError("Download failed: ${e.toString()}");
      try {
        if (outputDir != null && await outputDir.exists()) await outputDir.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  // --- Android 13+ Permissions ---
  static Future<void> _requestMediaPermission() async {
    final statuses = await [
      Permission.photos,
      Permission.videos,
      Permission.audio,
    ].request();
    if (statuses.values.any((status) => !status.isGranted)) {
      throw Exception('Media permissions denied');
    }
  }

  // --- Streaming Downloader ---
  Future<(String?, String)> _streamAndHashDownload(
      String url,
      String outputPath,
      String expectedHash,
      void Function(double progress) onProgress,
      ) async {
    final uri = Uri.parse(url);
    final client = ProxyConfig.createHttpClient();

    AppLogger.debug('Starting HTTP GET for $url');
    final request = await client.getUrl(uri);
    request.headers.add('User-Agent', 'Red-Courier/1.0');
    request.headers.add('Accept-Encoding', 'identity');

    // Filebin-specific cookie
    if (uri.host.contains("filebin.net")) {
      const verifiedCookieValue = '2024-05-24';
      request.headers.set('Cookie', 'verified=$verifiedCookieValue');
    }

    File? file;
    try {
      final response = await request.close();

      // Handle redirects
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null) {
          AppLogger.debug('Following redirect to: $location');
          return _streamAndHashDownload(
              uri.resolve(location).toString(), outputPath, expectedHash, onProgress);
        }
      }

      if (response.statusCode != 200) {
        AppLogger.error('HTTP ${response.statusCode} for $url');
        AppNotifier.showError('Failed to download. HTTP ${response.statusCode}.');
        return (null, outputPath);
      }

      final totalBytes = response.contentLength;
      if (totalBytes <= 0) {
        AppLogger.warn('Content length unknown for $url');
      }

      file = File(outputPath);
      final sink = file.openWrite(mode: FileMode.write);

      int receivedBytes = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        if (totalBytes > 0 && receivedBytes % (1024 * 1024) == 0) {
          final progress = receivedBytes / totalBytes;
          onProgress(progress.clamp(0.0, 1.0));
        }
      }

      await sink.close();
      onProgress(1.0);

      // Streamed SHA256 hash
      final fileStream = file.openRead();
      final hash = await sha256.bind(fileStream).first;
      final actualHash = hash.toString();

      // ZIP validation (4 bytes)
      final firstBytes = await file.openRead(0, 4).first;
      if (!_looksLikeZip(firstBytes)) {
        AppLogger.error('Invalid ZIP signature in downloaded file: $outputPath');
        AppNotifier.showError('Downloaded file is not a valid ZIP.');
        await file.delete();
        return (null, outputPath);
      }

      AppLogger.debug('Download complete: $outputPath (hash=$actualHash)');
      return (actualHash, outputPath);
    } catch (e) {
      AppLogger.error('Download error: $e');
      AppNotifier.showError('Streaming download failed: $e');
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
      return (null, outputPath);
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikeZip(List<int> bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }
}
