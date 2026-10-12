import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'i18n.dart';
import 'logger.dart';
import 'prefs.dart';

/// How often an unlocked group syncs on its own.
const syncIntervalMinutes = 10;

/// Local notifications about new deliveries.
///
/// Nothing goes through a push service: the app itself syncs while it is
/// unlocked (also in the background until the system pauses it) and shows a
/// notification when new deliveries arrived. The text names neither the
/// sender nor the group, because it may be visible on the lock screen.
class Notifications {
  static const prefKey = 'notify_new_deliveries';
  static const _askedKey = 'notify_permission_asked';
  static const _channelId = 'new_deliveries';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get enabled => Prefs.getBool(prefKey) ?? true;

  static Future<void> init() async {
    try {
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              linux: LinuxInitializationSettings(defaultActionName: 'Open'),
              windows: WindowsInitializationSettings(
                appName: 'RedCourier',
                appUserModelId: 'de.red.redcourier',
                guid: 'a81cd1c1-e8ad-4fb6-956c-80010c2d517a',
              ),
            ),
          ) ??
          false;
    } catch (e) {
      // For example no notification daemon on a minimal Linux desktop.
      AppLogger.warn('Notifications unavailable', e);
      _ready = false;
    }
  }

  /// Android 13+ asks the user once. Returns whether notifications may be shown.
  static Future<bool> requestPermission({bool onlyOnce = false}) async {
    if (!Platform.isAndroid) return true;
    if (onlyOnce && (Prefs.getBool(_askedKey) ?? false)) return true;
    await Prefs.set(_askedKey, true);
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    await Prefs.set(prefKey, value);
    if (value) await requestPermission();
  }

  static Future<void> newDeliveries(int count) async {
    if (!_ready || !enabled || count <= 0) return;
    try {
      await _plugin.show(
        id: 1,
        title: 'RedCourier',
        body: count == 1 ? tr('1 new delivery') : tr('{n} new deliveries', {'n': count}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            tr('New deliveries'),
            visibility: NotificationVisibility.private,
            category: AndroidNotificationCategory.message,
          ),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      AppLogger.warn('Notification failed', e);
    }
  }
}
