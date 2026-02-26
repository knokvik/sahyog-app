import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/src/widgets/control/clerk_auth.dart';
import 'package:clerk_flutter/src/widgets/ui/clerk_cached_image.dart';
import 'package:clerk_flutter/src/widgets/ui/common.dart';
import 'package:flutter/material.dart';

/// should we invert the logo for dark mode?
extension on clerk.SocialConnection {
  bool get invertLogoForDarkMode => const [
        clerk.Strategy.oauthApple,
        clerk.Strategy.oauthGithub,
        clerk.Strategy.oauthX,
        clerk.Strategy.oauthTiktok,
        clerk.Strategy.oauthNotion,
        clerk.Strategy.oauthVercel,
      ].contains(strategy);
}

/// The [SocialConnectionButton] is to be used with the authentication flow when working with
/// a an oAuth provider. When there is sufficient space, an [Icon] and [Text] description of
/// the provider. Else, just the [Icon].
///
@immutable
class SocialConnectionButton extends StatelessWidget {
  /// Constructs a new [SocialConnectionButton].
  const SocialConnectionButton({
    super.key,
    required this.connection,
    required this.onPressed,
  });

  /// Function to call when a strategy chosen
  final VoidCallback? onPressed;

  /// The oAuth provider this button represents.
  final clerk.SocialConnection connection;

  @override
  Widget build(BuildContext context) {
    final themeExtension = ClerkAuth.themeExtensionOf(context);
    final l10ns = ClerkAuth.localizationsOf(context);
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: onPressed == null ? 0.5 : 1.0,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF1E293B),
            side: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (connection.logoUrl.isNotEmpty) ...[
                ClerkCachedImage(
                  connection.logoUrl,
                  invertColors: connection.invertLogoForDarkMode &&
                      themeExtension.brightness == Brightness.dark,
                  width: 24,
                ),
                horizontalMargin16,
              ],
              Text(
                'Continue with ${connection.name}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
