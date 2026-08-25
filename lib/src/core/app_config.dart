import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

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

  static String get baseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;

    if (kIsWeb) {
      return localhostUrl;
    }

    try {
      if (Platform.isAndroid) {
        return androidEmulatorUrl;
      }
      if (Platform.isIOS || Platform.isMacOS) {
        return localhostUrl;
      }
    } catch (_) {}

    return physicalDeviceUrl;
  }
}
