class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Render Production Server
  static const productionUrl = 'http://localhost:3000';

  // Fallbacks for local development if needed, but primary is productionUrl
  static const androidBaseUrl = 'http://localhost:3000';
  static const iosBaseUrl = 'http://localhost:3000';

  static String get baseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;
    // For physical device testing, use the production Vercel URL
    return productionUrl;
  }
}
