import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:clerk_flutter/src/widgets/authentication/clerk_oauth_panel.dart';
import 'package:clerk_flutter/src/widgets/authentication/clerk_sign_in_panel.dart';
import 'package:flutter/material.dart';
import 'package:sahyog_app/src/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

import 'features/auth/auth_gate.dart';

const clerkPublishableKey =
    'pk_test_ZGlyZWN0LWhlcm1pdC04NC5jbGVyay5hY2NvdW50cy5kZXYk';

class SahyogApp extends StatelessWidget {
  const SahyogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ClerkAuth(
      config: ClerkAuthConfig(
        publishableKey: clerkPublishableKey,
        defaultLaunchMode: LaunchMode.externalApplication,
      ),
      child: MaterialApp(
        title: 'Sahyog',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.light,
        theme: AppTheme.lightTheme,
        home: ClerkAuthBuilder(
          signedOutBuilder: (_, __) => const _SignedOutScreen(),
          signedInBuilder: (_, authState) => AuthGate(authState: authState),
        ),
      ),
    );
  }
}

class _SignedOutScreen extends StatelessWidget {
  const _SignedOutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 48),
                Hero(
                  tag: 'app_logo',
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'lib/assets/favicon.png',
                      height: 60,
                      width: 60,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Sahyog',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF27B469),
                  ),
                ),
                Text(
                  'DISASTER RESPONSE NETWORK',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.grey[500],
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 48),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: const _CustomSignInArea(),
                ),
                const SizedBox(height: 48),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: Colors.grey[400]),
                    const SizedBox(width: 8),
                    Text(
                      'Secure SSL Connection',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomSignInArea extends StatelessWidget {
  const _CustomSignInArea();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 30,
            offset: const Offset(0, 15),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Sign In',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Connect with Google or use email',
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 32),
          ClerkOAuthPanel(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'OR',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(child: Divider()),
              ],
            ),
          ),
          ClerkSignInPanel(),
        ],
      ),
    );
  }
}
