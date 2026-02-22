import 'package:flutter/foundation.dart';

class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Local Network Server for physical device testing
  static const productionUrl = 'http://172.25.96.235:3000';

  // Android emulator reaches host machine via 10.0.2.2.
  static const androidBaseUrl = 'http://10.0.2.2:3000';
  static const iosBaseUrl = 'http://localhost:3000';

  static String get baseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;
    // For physical device testing, use the production Vercel URL
    return productionUrl;
  }
}
