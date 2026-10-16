import 'package:flutter/material.dart';

/// Main application configuration model
class AppConfig {
  final AppInfo app;
  final SplashScreenConfig splashScreen;
  final ThemeConfig theme;
  final OfflineConfig offline;
  final WebViewConfig webview;
  final NotificationsConfig notifications;
  final List<String> nativeUrlHandlers;
  final OnboardingConfig onboarding;

  AppConfig({
    required this.app,
    required this.splashScreen,
    required this.theme,
    required this.offline,
    required this.webview,
    required this.notifications,
    required this.nativeUrlHandlers,
    required this.onboarding,
  });

  factory AppConfig.fromMap(Map<dynamic, dynamic> map) {
    return AppConfig(
      app: AppInfo.fromMap(map['app'] ?? {}),
      splashScreen: SplashScreenConfig.fromMap(map['splash_screen'] ?? {}),
      theme: ThemeConfig.fromMap(map['theme'] ?? {}),
      offline: OfflineConfig.fromMap(map['offline'] ?? {}),
      webview: WebViewConfig.fromMap(map['webview'] ?? {}),
      notifications: NotificationsConfig.fromMap(map['notifications'] ?? {}),
      nativeUrlHandlers: (map['native_url_handlers'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      onboarding: OnboardingConfig.fromMap(map['onboarding'] ?? {}),
    );
  }
}

/// Application information
class AppInfo {
  final String name;
  final String websiteUrl;
  final String description;

  AppInfo({
    required this.name,
    required this.websiteUrl,
    required this.description,
  });

  factory AppInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppInfo(
      name: map['name']?.toString() ?? 'WebWrap',
      websiteUrl:
          map['website_url']?.toString() ?? 'https://flutter.dev',
      description: map['description']?.toString() ?? '',
    );
  }
}

/// Splash screen configuration
class SplashScreenConfig {
  final String image;
  final Color backgroundColor;
  final int durationSeconds;

  SplashScreenConfig({
    required this.image,
    required this.backgroundColor,
    required this.durationSeconds,
  });

  factory SplashScreenConfig.fromMap(Map<dynamic, dynamic> map) {
    return SplashScreenConfig(
      image: map['image']?.toString() ?? 'assets/splash/logo.png',
      backgroundColor: _parseColor(map['background_color']?.toString()),
      durationSeconds: map['duration_seconds'] as int? ?? 2,
    );
  }
}

/// Theme configuration
class ThemeConfig {
  final ThemeMode mode; // system, light, dark
  final ThemeColors light;
  final ThemeColors dark;

  ThemeConfig({
    required this.mode,
    required this.light,
    required this.dark,
  });

  factory ThemeConfig.fromMap(Map<dynamic, dynamic> map) {
    // Parse theme mode
    ThemeMode themeMode;
    final modeStr = map['dark_mode']?.toString().toLowerCase();
    switch (modeStr) {
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'dark':
        themeMode = ThemeMode.dark;
        break;
      case 'system':
      default:
        themeMode = ThemeMode.system;
        break;
    }

    return ThemeConfig(
      mode: themeMode,
      light: ThemeColors.fromMap(map['light'] ?? {}),
      dark: ThemeColors.fromMap(map['dark'] ?? {}, isDark: true),
    );
  }

  /// Get current theme based on brightness
  ThemeColors getTheme(Brightness brightness) {
    if (mode == ThemeMode.light) return light;
    if (mode == ThemeMode.dark) return dark;
    // ThemeMode.system
    return brightness == Brightness.dark ? dark : light;
  }
}

/// Individual theme colors
class ThemeColors {
  final Color primaryColor;
  final Color statusBarColor;
  final Brightness statusBarBrightness;
  final Color backgroundColor;

  ThemeColors({
    required this.primaryColor,
    required this.statusBarColor,
    required this.statusBarBrightness,
    required this.backgroundColor,
  });

  factory ThemeColors.fromMap(Map<dynamic, dynamic> map, {bool isDark = false}) {
    return ThemeColors(
      primaryColor: _parseColor(
        map['primary_color']?.toString(),
        fallback: isDark ? const Color(0xFF1976D2) : const Color(0xFF2196F3),
      ),
      statusBarColor: _parseColor(
        map['status_bar_color']?.toString(),
        fallback: isDark ? const Color(0xFF000000) : const Color(0xFF1976D2),
      ),
      statusBarBrightness: map['status_bar_brightness']?.toString() == 'light'
          ? Brightness.light
          : Brightness.dark,
      backgroundColor: _parseColor(
        map['background_color']?.toString(),
        fallback: isDark ? const Color(0xFF121212) : const Color(0xFFFFFFFF),
      ),
    );
  }
}

/// Offline configuration
class OfflineConfig {
  final bool enabled;
  final String message;
  final String subtitle;
  final bool showRetryButton;
  final String retryButtonText;
  final OfflineColors light;
  final OfflineColors dark;

  OfflineConfig({
    required this.enabled,
    required this.message,
    required this.subtitle,
    required this.showRetryButton,
    required this.retryButtonText,
    required this.light,
    required this.dark,
  });

  factory OfflineConfig.fromMap(Map<dynamic, dynamic> map) {
    return OfflineConfig(
      enabled: map['enabled'] as bool? ?? true,
      message: map['message']?.toString() ?? 'No Internet Connection',
      subtitle:
          map['subtitle']?.toString() ?? 'Check your connection and try again',
      showRetryButton: map['show_retry_button'] as bool? ?? true,
      retryButtonText: map['retry_button_text']?.toString() ?? 'Retry',
      light: OfflineColors.fromMap(map['light'] ?? {}),
      dark: OfflineColors.fromMap(map['dark'] ?? {}, isDark: true),
    );
  }

  /// Get current colors based on brightness
  OfflineColors getColors(Brightness brightness) {
    return brightness == Brightness.dark ? dark : light;
  }
}

/// Offline screen colors
class OfflineColors {
  final Color backgroundColor;
  final Color textColor;

  OfflineColors({
    required this.backgroundColor,
    required this.textColor,
  });

  factory OfflineColors.fromMap(Map<dynamic, dynamic> map, {bool isDark = false}) {
    return OfflineColors(
      backgroundColor: _parseColor(
        map['background_color']?.toString(),
        fallback: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      ),
      textColor: _parseColor(
        map['text_color']?.toString(),
        fallback: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF333333),
      ),
    );
  }
}

/// WebView configuration
class WebViewConfig {
  final bool enableJavascript;
  final bool enableDomStorage;
  final bool enableZoom;
  final String? userAgent;
  final bool clearCacheOnStart;
  final bool clearCookiesOnStart;
  final bool allowMediaPlayback;
  final bool allowInlineMediaPlayback;

  final bool showLoader;
  final String loaderStyle;

  WebViewConfig({
    required this.enableJavascript,
    required this.enableDomStorage,
    required this.enableZoom,
    this.userAgent,
    required this.clearCacheOnStart,
    required this.clearCookiesOnStart,
    required this.allowMediaPlayback,
    required this.allowInlineMediaPlayback,
    this.showLoader = true,
    this.loaderStyle = 'three_bounce',
  });

  factory WebViewConfig.fromMap(Map<dynamic, dynamic> map) {
    return WebViewConfig(
      enableJavascript: map['enable_javascript'] as bool? ?? true,
      enableDomStorage: map['enable_dom_storage'] as bool? ?? true,
      enableZoom: map['enable_zoom'] as bool? ?? false,
      userAgent: map['user_agent']?.toString(),
      clearCacheOnStart: map['clear_cache_on_start'] as bool? ?? false,
      clearCookiesOnStart: map['clear_cookies_on_start'] as bool? ?? false,
      allowMediaPlayback: map['allow_media_playback'] as bool? ?? true,
      allowInlineMediaPlayback:
          map['allow_inline_media_playback'] as bool? ?? true,
      showLoader: map['show_loader'] as bool? ?? true,
      loaderStyle: map['loader_style']?.toString() ?? 'three_bounce',
    );
  }
}

/// Notifications configuration
class NotificationsConfig {
  final bool enabled;
  final bool firebaseEnabled;
  final bool showInForeground;
  final bool playSound;
  final String icon;

  NotificationsConfig({
    required this.enabled,
    required this.firebaseEnabled,
    required this.showInForeground,
    required this.playSound,
    required this.icon,
  });

  factory NotificationsConfig.fromMap(Map<dynamic, dynamic> map) {
    return NotificationsConfig(
      enabled: map['enabled'] as bool? ?? false,
      firebaseEnabled: map['firebase_enabled'] as bool? ?? false,
      showInForeground: map['show_in_foreground'] as bool? ?? true,
      playSound: map['play_sound'] as bool? ?? true,
      icon: map['icon']?.toString() ?? '@mipmap/ic_launcher',
    );
  }
}

/// Onboarding screens configuration
class OnboardingConfig {
  final bool enabled;
  final bool alwaysShow;
  final List<OnboardingScreenItem> screens;

  OnboardingConfig({
    required this.enabled,
    required this.alwaysShow,
    required this.screens,
  });

  factory OnboardingConfig.fromMap(Map<dynamic, dynamic> map) {
    final screensList = (map['screens'] as List<dynamic>?)
            ?.map((e) => OnboardingScreenItem.fromMap(e as Map<dynamic, dynamic>))
            .toList() ??
        [];

    return OnboardingConfig(
      enabled: map['enabled'] as bool? ?? true,
      alwaysShow: map['always_show'] as bool? ?? false,
      screens: screensList.isNotEmpty ? screensList : _defaultScreens,
    );
  }

  static final List<OnboardingScreenItem> _defaultScreens = [
    OnboardingScreenItem(
      titlePrefix: "Welcome to",
      titleHighlight: "eAuto Dealer",
      description:
          "Manage your dealership operations, inventory, sales, and reports from one smart app.",
      image: "assets/onboarding/intro_1.jpg",
    ),
    OnboardingScreenItem(
      titlePrefix: "Smart Inventory",
      titleHighlight: "Management",
      description:
          "Track your vehicle stock in real-time, update specifications, and showcase high-resolution car galleries.",
      image: "assets/onboarding/intro_2.jpg",
    ),
    OnboardingScreenItem(
      titlePrefix: "Lead Tracking &",
      titleHighlight: "CRM Automation",
      description:
          "Capture buyer inquiries, schedule test drives, and close vehicle deals faster than ever.",
      image: "assets/onboarding/intro_3.jpg",
    ),
    OnboardingScreenItem(
      titlePrefix: "Dealership Performance &",
      titleHighlight: "Analytics",
      description:
          "Gain complete visibility over sales figures, profit margins, and team performance with real-time reports.",
      image: "assets/onboarding/intro_4.jpg",
    ),
  ];
}

/// Single onboarding screen item
class OnboardingScreenItem {
  final String titlePrefix;
  final String titleHighlight;
  final String description;
  final String image;

  OnboardingScreenItem({
    required this.titlePrefix,
    required this.titleHighlight,
    required this.description,
    required this.image,
  });

  factory OnboardingScreenItem.fromMap(Map<dynamic, dynamic> map) {
    return OnboardingScreenItem(
      titlePrefix: map['title_prefix']?.toString() ?? '',
      titleHighlight: map['title_highlight']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      image: map['image']?.toString() ?? '',
    );
  }
}

/// Helper function to parse color from hex string
Color _parseColor(String? hexString, {Color fallback = Colors.white}) {
  if (hexString == null || hexString.isEmpty) {
    return fallback;
  }

  try {
    // Remove # if present
    String colorString = hexString.replaceAll('#', '');

    // Add FF for alpha if not present (6 chars)
    if (colorString.length == 6) {
      colorString = 'FF$colorString';
    }

    return Color(int.parse(colorString, radix: 16));
  } catch (e) {
    return fallback;
  }
}
