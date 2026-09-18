import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Mac WiFi IP for physical devices & network access
  static const localWifiIp = '10.78.250.27';
  static const port = '3000';

  // Primary URL for iOS Simulator & macOS
  static const localhostUrl = 'http://localhost:$port';
  // Primary URL for Android Emulator
  static const androidEmulatorUrl = 'http://10.0.2.2:$port';
  // Primary URL for Physical Devices on local WiFi
  static const physicalDeviceUrl = 'http://$localWifiIp:$port';
  // Production Deployed URL (release APK)
  static const productionUrl = 'https://sahyog-wq9v.onrender.com';

  static String get baseUrl {
    String url = _envBaseUrl;

    if (url.isEmpty) {
      if (kReleaseMode) {
        url = productionUrl;
      } else if (kIsWeb) {
        url = localhostUrl;
      } else {
        try {
          if (Platform.isAndroid) {
            url = androidEmulatorUrl;
          } else if (Platform.isIOS || Platform.isMacOS) {
            url = localhostUrl;
          } else {
            url = physicalDeviceUrl;
          }
        } catch (_) {
          url = physicalDeviceUrl;
        }
      }
    }
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }
}
