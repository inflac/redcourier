// proxy_config.dart
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';

class ProxyConfig {
  static bool enabled = false;
  static String host = "127.0.0.1";
  static int port = 8080;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool("proxy_enabled") ?? false;
    host = prefs.getString("proxy_host") ?? "127.0.0.1";
    port = prefs.getInt("proxy_port") ?? 8080;
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool("proxy_enabled", enabled);
    prefs.setString("proxy_host", host);
    prefs.setInt("proxy_port", port);
    AppLogger.debug("Proxy enabled: ${ProxyConfig.enabled}, host=${ProxyConfig.host}, port=${ProxyConfig.port}");
  }

  /// Create a configured HttpClient
  static HttpClient createHttpClient() {
    final client = HttpClient();

    if (enabled) {
      client.findProxy = (uri) {
        return "PROXY $host:$port;";
      };
    } else {
      client.findProxy = null;
    }

    return client;
  }
}
