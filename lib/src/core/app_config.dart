import 'voice_sos_local.example.dart' as voice_local_example;
// Optional local override file (not tracked in git). You can create this
// yourself by copying voice_sos_local.example.dart to voice_sos_local.dart
// and setting your real key there.
// ignore: uri_does_not_exist
import 'voice_sos_local.dart' as voice_local;

class AppConfig {
  static const _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  // Render Production Server
  static const productionUrl = 'http://10.165.159.27:3000';

  // Fallbacks for local development if needed, but primary is productionUrl
  static const androidBaseUrl = 'http://10.165.159.27:3000';
  static const iosBaseUrl = 'http://10.165.159.27:3000';

  static String get baseUrl {
    if (_envBaseUrl.isNotEmpty) return _envBaseUrl;
    // For physical device testing, use the production Vercel URL
    return productionUrl;
  }

  // Optional Picovoice access key for voice‑activated SOS.
  // Configure at build time via:
  //   flutter run --dart-define=PICOVOICE_ACCESS_KEY=...
  static const _voiceAccessKey = String.fromEnvironment('PICOVOICE_ACCESS_KEY');

  static String? get voiceAccessKey {
    if (_voiceAccessKey.isNotEmpty) return _voiceAccessKey;
    if (voice_local.voiceAccessKeyOverride.isNotEmpty) {
      return voice_local.voiceAccessKeyOverride;
    }
    if (voice_local_example.voiceAccessKeyOverride.isNotEmpty) {
      return voice_local_example.voiceAccessKeyOverride;
    }
    return null;
  }
}
