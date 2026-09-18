import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Mac/Windows WiFi IP for physical devices & network access during local testing
  static const localWifiIp = '192.168.0.106';
  static const port = '3000';

  // Primary URL for iOS Simulator & macOS
  static const localhostUrl = 'http://localhost:$port';
  // Primary URL for Android Emulator
  static const androidEmulatorUrl = 'http://10.0.2.2:$port';
  
  // Local Development URL
  static const localDevelopmentUrl = 'http://$localWifiIp:$port';
  
  // Production Deployed URL
  static const productionUrl = 'https://sahyog-wq9v.onrender.com';

  static String get baseUrl {
    String url = _envBaseUrl;
    
    if (url.isEmpty) {
      // 1. ALWAYS use the Production URL when the app is built for release (APK)
      if (kReleaseMode) {
        url = productionUrl;
      } 
      // 2. Otherwise, we are in debug mode, use local environment logic
      else if (kIsWeb) {
        url = localhostUrl;
      } else {
        try {
          if (Platform.isAndroid) {
            // For Android physical device in debug mode
            url = localDevelopmentUrl;
          } else if (Platform.isIOS || Platform.isMacOS) {
            url = localhostUrl;
          } else {
            url = localDevelopmentUrl;
          }
        } catch (_) {
          url = localDevelopmentUrl;
        }
      }
    }
    // Remove any trailing slash to prevent double slashes (//) in endpoint paths
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }
}
