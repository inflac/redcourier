import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:redcourier/app_controller.dart';
import 'package:redcourier/i18n.dart';
import 'package:redcourier/main.dart';
import 'package:redcourier/prefs.dart';

/// Desktop layout: plain text fields instead of the on-screen keyboard.
final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

/// Widget tests run on a fake clock; real I/O (files, isolates, crypto) only
/// makes progress inside runAsync. These helpers alternate between both.
Future<void> idle(WidgetTester t, [int ms = 50]) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  // Advance the fake clock too, so animations and snack bar queues move on.
  await t.pump(Duration(milliseconds: ms));
}

/// Lets real work run until [finder] shows up.
Future<void> waitFor(WidgetTester t, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>();
      fail('Timed out waiting for $finder. On screen: ${texts.join(' | ')}');
    }
    await idle(t);
  }
}

/// Lets real work run until [finder] is gone.
Future<void> waitGone(WidgetTester t, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for $finder to disappear');
    await idle(t);
  }
}

/// Taps "Sync" on the home screen once no other sync is running.
Future<void> syncNow(WidgetTester t, {bool waitDone = true}) async {
  // A sync scheduled for the next frame (start, resume) must run first,
  // otherwise the tap is ignored while it runs with older data.
  for (var i = 0; i < 5; i++) {
    await idle(t);
  }
  await waitFor(t, find.byIcon(Icons.sync));
  await t.tap(find.byTooltip('Sync'));
  await t.pump();
  if (waitDone) await waitFor(t, find.byIcon(Icons.sync));
}

Future<void> tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  await t.ensureVisible(f.last);
  await t.tap(f.last);
  await t.pump();
}

Future<void> enter(WidgetTester t, String label, String text) async {
  final f = find.widgetWithText(TextField, label);
  await t.ensureVisible(f.first);
  await t.enterText(f.first, text);
  await t.pump();
}

/// Big screen, English, settings in [dir], package info for the settings page.
Future<void> prepare(WidgetTester t, Directory dir) async {
  t.view.physicalSize = const Size(1200, 2000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  PackageInfo.setMockInitialValues(
      appName: 'RedCourier', packageName: 'de.red.redcourier', version: '0.0.1', buildNumber: '1', buildSignature: '');
  await t.runAsync(() => Prefs.init(dir));
  I18n.language.value = 'en';
}

/// Shows the app for [c]; [init] runs the controller's start (skip it if
/// the test prepared the controller already).
Future<void> pumpApp(WidgetTester t, AppController c, Directory dir, {bool init = true}) async {
  await t.pumpWidget(App(controller: c, themeMode: ValueNotifier(ThemeMode.light)));
  if (init) await t.runAsync(() => c.init(dir));
  await t.pump();
}

/// Disposes the app (periodic sync timer) and lets snack bars expire.
Future<void> unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 10));
}
