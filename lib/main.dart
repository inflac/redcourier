import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'logger.dart';
import 'keyboard.dart';
import 'upload.dart';
import 'download.dart';
import 'app_notifier.dart';
import 'proxy.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ProxyConfig.load();
  //AppLogger.init(isEnabled: !kReleaseMode);
  AppLogger.init(isEnabled: true);
  runApp(const App());
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Red Courier',
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: _buildLightTheme(),
          darkTheme: _buildDarkTheme(),
          themeMode: themeMode,
          home: FileTransferHome(themeModeNotifier: themeModeNotifier),
        );
      },
    );
  }

  ThemeData _buildLightTheme() {
    const primaryColor = Color(0xFFB22222);
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      cardColor: const Color(0xFFEEEEEE),
      primaryColor: primaryColor,
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: primaryColor,
        onPrimary: Colors.white,
        surface: Color(0xFFEEEEEE),
        onSurface: Color(0xFF1C1C1C),
        secondary: Color(0xFF666666),
        onSecondary: Color(0xFF1C1C1C),
        error: Colors.red,
        onError: Colors.white,
      ),
      dividerColor: const Color(0xFFDADADA),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    const primaryColor = Color(0xFFB22222);
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF222222),
      cardColor: const Color(0xFF2C2C2C),
      primaryColor: primaryColor,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        onPrimary: Colors.white,
        surface: Color(0xFF2C2C2C),
        onSurface: Colors.white,
        secondary: Color(0xFFAAAAAA),
        onSecondary: Colors.white,
        error: Colors.red,
        onError: Colors.white,
      ),
      dividerColor: const Color(0xFF444444),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class FileTransferHome extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeModeNotifier;
  const FileTransferHome({super.key, required this.themeModeNotifier});

  @override
  State<FileTransferHome> createState() => _FileTransferHomeState();
}

class _FileTransferHomeState extends State<FileTransferHome>
    with SingleTickerProviderStateMixin {


  String? selectedFile;
  String? generatedPassword;
  String? downloadID;
  String? downloadURI;
  bool passwordVisible = false;
  bool isLoading = false;

  final DownloadManager downloadManager = DownloadManager();
  DownloadStatus? currentDownloadStatus;
  late StreamSubscription<DownloadStatus> _downloadStatusSubscription;

  UploadStatus? currentUploadStatus;
  late StreamSubscription<UploadStatus> _uploadStatusSubscription;

  late TabController _tabController;
  late AppLinks _appLinks;

  final UploadManager uploadManager = UploadManager();
  final urlController = TextEditingController();
  final passwordController = TextEditingController();
  final FocusNode downloadIDFocusNode = FocusNode();
  final FocusNode passwordFocusNode = FocusNode();
  TextEditingController? currentController;
  bool showKeyboard = false;

  int _tapCount = 0;
  DateTime _firstTapTime = DateTime.now();

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    downloadIDFocusNode.addListener(_handleFocusChange);
    passwordFocusNode.addListener(_handleFocusChange);

    _tabController.addListener(() {
      if (_tabController.indexIsChanging) _hideKeyboard();
    });

    _initDeepLinkListener();

    // Add Stream subscription
    _uploadStatusSubscription = uploadManager.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          currentUploadStatus = status;
          // Optional: Set isLoading to false, if final step is reached
          if (status.progress == 1.0 && status.statusText.contains("Finalizing")) {
            isLoading = false;
          }
        });
      }
    });

    _downloadStatusSubscription = downloadManager.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          currentDownloadStatus = status;
          // Set isLoading to false, if final step is reached
          if (status.progress != null && status.progress! >= 1.0) {
            isLoading = false;
          }
        });
      }
    });
  }

  void _handleFocusChange() {
    setState(() {
      showKeyboard = downloadIDFocusNode.hasFocus || passwordFocusNode.hasFocus;
      if (downloadIDFocusNode.hasFocus) {
        currentController = urlController;
      } else if (passwordFocusNode.hasFocus) {
        currentController = passwordController;
      } else {
        currentController = null;
      }
    });
  }

  void _hideKeyboard() {
    setState(() {
      showKeyboard = false;
      currentController = null;
    });
    FocusScope.of(context).unfocus();
  }

  void _initDeepLinkListener() async {
    _appLinks = AppLinks();

    _appLinks.uriLinkStream.listen(
          (Uri? uri) {
        if (uri != null) {
          _processDeepLink(uri);
        } else {
          AppNotifier.showError("Received null URI from deep link stream");
        }
      },
      onError: (err, stack) {
        AppNotifier.showError("Error while handling deep link: $err");
      },
    );
  }

  void _processDeepLink(Uri uri) {
    if (uri.scheme == 'redcourier' && uri.host == 'download') {
      final downloadIDParam = uri.queryParameters['downloadID'];
      final passwordParam = uri.queryParameters['password'];

      if (downloadIDParam != null && passwordParam != null) {
        try {
          final downloadID = Uri.decodeComponent(downloadIDParam);

          String password = '';
          try {
            password = utf8.decode(
              base64Url.decode(Uri.decodeComponent(passwordParam)),
            );
          } catch (e) {
            AppNotifier.showError("Failed to decode password from deep link.");
            return;
          }

          setState(() {
            urlController.text = downloadID;
            passwordController.text = password;
          });

          // Do not automatically download
          //DownloadManager.downloadAndDecrypt(downloadID, password);
        } catch (e) {
          AppNotifier.showError("Failed to decode deep link: $e");
        }
      } else {
        AppNotifier.showError("Deep link is missing parameters.");
      }
    } else {
      AppNotifier.showError("Invalid deep link: wrong scheme or host.");
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    downloadIDFocusNode.dispose();
    passwordFocusNode.dispose();
    urlController.dispose();
    passwordController.dispose();

    _downloadStatusSubscription.cancel();
    downloadManager.dispose();

    _uploadStatusSubscription.cancel();
    uploadManager.dispose();
    super.dispose();
  }

  void _onTitleTap() {
    final now = DateTime.now();
    if (now.difference(_firstTapTime) > const Duration(seconds: 2)) {
      _tapCount = 0;
      _firstTapTime = now;
    }
    _tapCount++;
    if (_tapCount >= 5) {
      _tapCount = 0;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SettingsPage(themeModeNotifier: widget.themeModeNotifier),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _onTitleTap,
            child: const Text("Red Courier"),
          ),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: "Download"),
              Tab(text: "Upload"),
            ],
          ),
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      _hideKeyboard(); // hide keyboard on scroll
                      return false;
                    },
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildDownloadTab(),
                        _buildUploadTab(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (showKeyboard && _isMobile)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: CustomKeyboard(
                  onKeyPress: (key) {
                    setState(() {
                      if (currentController != null) currentController!.text += key;
                    });
                  },
                  onBackspace: () {
                    setState(() {
                      if (currentController != null && currentController!.text.isNotEmpty) {
                        currentController!.text = currentController!.text.substring(
                          0,
                          currentController!.text.length - 1,
                        );
                      }
                    });
                  },
                  onClear: () => currentController?.clear(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadTab() {

    // Status indicator for the Download
    Widget statusIndicator = Container();

    // Condition: Only show, if isLoading is true AND there is a currentDownloadStatus
    if (isLoading && currentDownloadStatus != null) {
      final status = currentDownloadStatus!;

      statusIndicator = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Text(
            status.statusText, // Shows current status text
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),

          LinearProgressIndicator(
            value: status.progress,
            minHeight: 10,
            borderRadius: BorderRadius.circular(5),
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 4),

          Text(
            status.progress != null
                ? "Progress: ${(status.progress! * 100).toStringAsFixed(1)}%"
                : "Decryption: In Progress...", // Text für unbestimmten Fortschritt
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: urlController,
            focusNode: downloadIDFocusNode,
            readOnly: !_isMobile ? false : true,
            decoration: const InputDecoration(
              labelText: "Download-ID",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            focusNode: passwordFocusNode,
            readOnly: !_isMobile ? false : true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Password",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: isLoading ? null : () async {
              _hideKeyboard();
              final input = urlController.text.trim();
              final password = passwordController.text.trim();

              if (input.isEmpty || password.isEmpty) {
                AppNotifier.showError("Please enter Download-ID and Password!");
                return;
              }

              setState(() {
                isLoading = true;
                currentDownloadStatus = null; // Reset status on start
              });

              try {
                // The DownloadManager sends status updates to the UI
                await downloadManager.downloadAndDecrypt(input, password);

              } catch (e) {
                AppNotifier.showError("An unexpected error occurred while downloading.");
              } finally {
                // Ensure the isloading indicator is reset if the stream does not reach 1.0
                if (mounted && currentDownloadStatus?.progress != 1.0) {
                  setState(() => isLoading = false);
                }
              }
            },
            icon: Icon(Icons.download, color: Theme.of(context).colorScheme.onPrimary),
            label: isLoading ? const Text("Downloading...") : const Text("Start Downlaod"),
          ),

          // Hinzufügen der Statusanzeige
          statusIndicator,
        ],
      ),
    );
  }

  Widget _buildUploadTab() {
    Widget statusIndicator = Container();
    if (isLoading && currentUploadStatus != null) {
      final status = currentUploadStatus!;

      statusIndicator = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Text(
            status.statusText,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: status.progress > 0.0 ? status.progress : null,
            minHeight: 10,
            borderRadius: BorderRadius.circular(5),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: () async {
              await uploadManager.chooseFiles();
              setState(() {});
            },
            icon: Icon(Icons.folder_open, color: Theme.of(context).colorScheme.onPrimary),
            label: Text(uploadManager.fileCount > 0
                ? "${uploadManager.fileCount} files selected"
                : "Choose Files"),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: isLoading ? null : () async {
              setState(() {
                isLoading = true;
                currentUploadStatus = null; // Reset status on start
              });
              try {
                // uploadFiles sends status updates to the UI
                final result = await uploadManager.uploadFiles();
                if (result != null) {
                  setState(() {
                    generatedPassword = result['password'];
                    downloadID = result['downloadID'];
                    downloadURI = result['downloadURI'];
                    uploadManager.selectedFiles.clear();
                  });
                } else {
                  // Reset state if upload failed
                  if (mounted) setState(() => isLoading = false);
                  if (context.mounted) AppNotifier.showInfo("Upload failed. Please try again.");
                }
              } catch (e) {
                isLoading = false;
                AppNotifier.showError("An unexpected error occurred while uploading.");
                AppLogger.error("Error: $e");
              }
            },
            icon: Icon(Icons.upload, color: Theme.of(context).colorScheme.onPrimary),
            label: Text(isLoading ? "Uploading..." : "Start Upload"),
          ),

          statusIndicator,
          const SizedBox(height: 30),
          if (downloadID != null) ...[
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        downloadID!,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: downloadID!));
                    AppNotifier.showInfo("Download-ID copied");
                  },
                  icon: const Icon(Icons.copy),
                  tooltip: "Copy Link",
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (generatedPassword != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => passwordVisible = !passwordVisible),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          passwordVisible ? generatedPassword! : "••••••••••••••••",
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: generatedPassword!));
                      AppNotifier.showInfo("Password copied");
                    },
                    icon: const Icon(Icons.copy),
                    tooltip: "Password copied",
                  ),
                ],
              ),
            const SizedBox(height: 20),
            if (downloadURI != null)
              Center(
                child: GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: downloadURI!));
                    AppNotifier.showInfo("Download-URI copied");
                  },
                  child: SizedBox(
                    width: 180,
                    height: 180,
                    child: QrImageView(
                      data: downloadURI!,
                      eyeStyle: QrEyeStyle(
                        eyeShape: QrEyeShape.square, // oder QrEyeShape.circle
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black,
                      ),
                      dataModuleStyle: QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square, // oder QrDataModuleShape.circle
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black,
                      ),
                      errorStateBuilder: (context, error) =>
                      const Center(child: Text("Error generating QR")),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeModeNotifier;
  const SettingsPage({super.key, required this.themeModeNotifier});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String version = '';
  String buildDate = '';

  ThemeMode? selectedThemeMode;

  @override
  void initState() {
    super.initState();
    selectedThemeMode = widget.themeModeNotifier.value;
    _loadPackageInfo();
    _loadBuildDate();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    setState(() => version = info.version);
  }

  void _loadBuildDate() {
    buildDate = DateTime.now().toIso8601String();
  }


  Future<void> clearTempFiles() async {
    try {
      final tempDir = Directory.systemTemp;
      final tempFolders = tempDir.listSync().where((f) => f.path.contains('encrypted_files_'));
      for (final folder in tempFolders) {
        await folder.delete(recursive: true);
      }
      AppNotifier.showInfo("Temporary files deleted successfully.");
    } catch (e) {
      AppNotifier.showError("Failed to delete temporary files: $e");
    }
  }

  Future<void> clearDownloadFolder() async {
    Directory baseDir;

    try {
      if (Platform.isAndroid) {
        baseDir = Directory('/storage/emulated/0/Download/RedCourier');
      } else {
        final downloadsDir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        baseDir = Directory('${downloadsDir.path}/RedCourier');
      }

      if (await baseDir.exists()) {
        await baseDir.delete(recursive: true); // Deletes the entire RedCourier folder including contents
        AppNotifier.showInfo("Download folder cleared.");
      } else {
        AppNotifier.showInfo("Download folder does not exist.");
      }
    } catch (e) {
      AppNotifier.showError("Error while clearing the download folder: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 20),
            DropdownButtonFormField<ThemeMode>(
              initialValue: selectedThemeMode,
              decoration: const InputDecoration(
                labelText: "Theme",
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text("System")),
                DropdownMenuItem(value: ThemeMode.light, child: Text("Light")),
                DropdownMenuItem(value: ThemeMode.dark, child: Text("Dark")),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    selectedThemeMode = value;
                    widget.themeModeNotifier.value = value;
                  });
                }
              },
            ),
            const SizedBox(height: 30),

            SwitchListTile(
              title: const Text("Use Proxy (experimental)"),
              value: ProxyConfig.enabled,
              onChanged: (value) {
                setState(() {
                  ProxyConfig.enabled = value;
                });
                ProxyConfig.save();
              },
            ),

            if (ProxyConfig.enabled) ...[
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: "Proxy host",
                  border: OutlineInputBorder(),
                ),
                controller: TextEditingController(text: ProxyConfig.host),
                onChanged: (v) {
                  ProxyConfig.host = v;
                  ProxyConfig.save();
                },
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: "Proxy port",
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                controller: TextEditingController(text: ProxyConfig.port.toString()),
                onChanged: (v) {
                  ProxyConfig.port = int.tryParse(v) ?? 8080;
                  ProxyConfig.save();
                },
              ),
            ],

            const SizedBox(height: 30),

            // Button: Clear temp files
            ElevatedButton.icon(
              onPressed: clearTempFiles,
              icon: const Icon(Icons.delete_sweep),
              label: const Text("Clear temporary files"),
            ),
            const SizedBox(height: 12),

            // Button: Clear download folder
            ElevatedButton.icon(
              onPressed: clearDownloadFolder,
              icon: const Icon(Icons.folder_delete),
              label: const Text("Clear downloads"),
            ),
            const Spacer(),
            Column(
              children: [
                Text("Version: $version"),
                const SizedBox(height: 4),
                Text("Build Date: $buildDate"),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
