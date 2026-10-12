import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_controller.dart';
import 'core/tor.dart';
import 'i18n.dart';
import 'logger.dart';
import 'notifications.dart';
import 'prefs.dart';
import 'theme.dart';
import 'ui/home_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/update_ui.dart';
import 'ui/setup_screens.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Lock the app after it has been in the background this long.
const autoLockAfter = Duration(minutes: 5);

// coverage:ignore-start
// The entry point needs the real platform plugins; App below is tested.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything else: no connection may bypass Tor.
  TorNetwork.installGuard();
  AppLogger.init(isEnabled: !kReleaseMode);
  final dataDir = await resolveDataDir();
  await Prefs.init(dataDir);
  await I18n.load();
  await loadTorSettings();
  await Notifications.init();
  await initUpdates();
  final themeMode = ValueNotifier(await loadThemeMode());
  final controller = AppController();
  runApp(App(controller: controller, themeMode: themeMode));
  await controller.init(dataDir);
  // Like CalSec: check for updates once at start (installed versions only).
  await runStartupUpdateCheck(navigatorKey.currentState);
}
// coverage:ignore-end

class App extends StatefulWidget {
  final AppController controller;
  final ValueNotifier<ThemeMode> themeMode;
  const App({super.key, required this.controller, required this.themeMode});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  DateTime? _backgroundSince;

  @override
  void initState() {
    super.initState();
    appThemeMode = widget.themeMode;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = widget.controller;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      final unlocked = c.phase == AppPhase.ready || c.phase == AppPhase.noGroup;
      if (since != null && unlocked && DateTime.now().difference(since) > autoLockAfter) {
        navigatorKey.currentState?.popUntil((r) => r.isFirst);
        c.lock();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: I18n.language,
      builder: (context, lang, _) => ValueListenableBuilder<ThemeMode>(
        valueListenable: widget.themeMode,
        builder: (context, mode, _) => MaterialApp(
          title: 'RedCourier',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: scaffoldMessengerKey,
          navigatorKey: navigatorKey,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: mode,
          locale: Locale(lang),
          supportedLocales: [for (final code in I18n.supported.keys) Locale(code)],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final c = widget.controller;
              // Keys include the language, so every screen is rebuilt in the new language.
              switch (c.phase) {
                case AppPhase.loading:
                  return const Scaffold(body: Center(child: CircularProgressIndicator()));
                case AppPhase.noIdentity:
                  return WelcomeScreen(key: ValueKey('welcome-$lang'), app: c);
                case AppPhase.locked:
                  return UnlockScreen(key: ValueKey('unlock-${c.groupName}-$lang'), app: c);
                case AppPhase.noGroup:
                  return GroupSetupScreen(
                      key: ValueKey('setup-${c.groupName}-$lang-${identityHashCode(c.lastCreateFailure)}'),
                      app: c);
                case AppPhase.ready:
                  return HomeScreen(
                      key: ValueKey('home-${identityHashCode(c.session)}-$lang'),
                      app: c,
                      themeMode: widget.themeMode);
              }
            },
          ),
        ),
      ),
    );
  }
}
