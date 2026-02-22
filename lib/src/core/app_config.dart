class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Render Production Server
  static const productionUrl = 'https://sahyog-uo2y.onrender.com';

  // Fallbacks for local development if needed, but primary is productionUrl
  static const androidBaseUrl = 'https://sahyog-uo2y.onrender.com';
  static const iosBaseUrl = 'https://sahyog-uo2y.onrender.com';

  static String get baseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;
    // For physical device testing, use the production Vercel URL
    return productionUrl;
  }
}
