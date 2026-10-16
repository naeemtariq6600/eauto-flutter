import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'onboarding_screen.dart';
import 'webview_screen.dart';

/// Customizable splash screen
class SplashScreen extends StatefulWidget {
  final AppConfig config;

  const SplashScreen({
    super.key,
    required this.config,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToNextScreen();
  }

  /// Navigate to Onboarding (if first launch) or WebView after splash duration
  Future<void> _navigateToNextScreen() async {
    await Future.delayed(
      Duration(seconds: widget.config.splashScreen.durationSeconds),
    );

    if (!mounted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSeenOnboarding = prefs.getBool('has_seen_onboarding') ?? false;

      final shouldShowOnboarding = widget.config.onboarding.enabled &&
          (!hasSeenOnboarding || widget.config.onboarding.alwaysShow);

      if (!mounted) return;

      if (shouldShowOnboarding) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                OnboardingScreen(config: widget.config),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
        return;
      }
    } catch (e) {
      debugPrint('Error reading onboarding status: $e');
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              WebViewScreen(config: widget.config),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Get current brightness
    final currentBrightness = MediaQuery.of(context).platformBrightness;
    final currentTheme = widget.config.theme.getTheme(currentBrightness);

    // Set status bar style
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: widget.config.splashScreen.backgroundColor,
        statusBarIconBrightness: currentTheme.statusBarBrightness,
        statusBarBrightness: currentTheme.statusBarBrightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
    );

    return Scaffold(
      backgroundColor: widget.config.splashScreen.backgroundColor,
      body: Center(
        child: _buildSplashContent(currentTheme),
      ),
    );
  }

  Widget _buildSplashContent(ThemeColors currentTheme) {
    // Solo logo centrato, nessun loader
    return _buildLogo(currentTheme);
  }

  Widget _buildLogo(ThemeColors currentTheme) {
    try {
      return Image.asset(
        widget.config.splashScreen.image,
        width: 150,
        height: 150,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          // Fallback if image not found
          return Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              color: currentTheme.primaryColor.withAlpha(51),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.web,
              size: 80,
              color: currentTheme.primaryColor,
            ),
          );
        },
      );
    } catch (e) {
      // Fallback widget if image fails to load
      return Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          color: currentTheme.primaryColor.withAlpha(51),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          Icons.web,
          size: 80,
          color: currentTheme.primaryColor,
        ),
      );
    }
  }
}
