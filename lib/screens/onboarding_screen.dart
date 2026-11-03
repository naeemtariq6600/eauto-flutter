import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import 'webview_screen.dart';

/// Pixel-perfect 4-step onboarding screen for first-time app launch
class OnboardingScreen extends StatefulWidget {
  final AppConfig config;

  const OnboardingScreen({
    super.key,
    required this.config,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  List<OnboardingScreenItem> get _screens =>
      widget.config.onboarding.screens;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Mark onboarding as completed in SharedPreferences and proceed to WebView
  Future<void> _completeOnboarding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_seen_onboarding', true);
    } catch (e) {
      debugPrint('Error saving onboarding state: $e');
    }

    if (!mounted) return;

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

  /// Handle Next button or swipe completion
  void _onNextPressed() {
    if (_currentPage < _screens.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _completeOnboarding();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentBrightness = MediaQuery.of(context).platformBrightness;
    final currentTheme = widget.config.theme.getTheme(currentBrightness);
    final primaryColor = currentTheme.primaryColor;

    // Dark status bar icons for high contrast on light backgrounds
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Background PageView with images
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _screens.length,
              physics: const BouncingScrollPhysics(),
              onPageChanged: (index) {
                setState(() {
                  _currentPage = index;
                });
              },
              itemBuilder: (context, index) {
                return _buildVisualBackground(_screens[index], primaryColor);
              },
            ),
          ),

          // Top Header: Brand Logo & Skip Button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildBrandLogo(),
                    _buildSkipButton(),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Curved Sheet with Onboarding Info & Controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomCard(primaryColor),
          ),
        ],
      ),
    );
  }

  /// Top Left Brand Logo (eAuto Dealer icon)
  Widget _buildBrandLogo() {
    return Image.asset(
      'assets/icon/app-icon.png',
      height: 60,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) => const Icon(
        Icons.directions_car_filled_rounded,
        size: 50,
        color: _buttonColor,
      ),
    );
  }

  /// Brand button color #1f00a7
  static const Color _buttonColor = Color(0xFF1F00A7);

  /// Top Right "Skip >" Pill Button
  Widget _buildSkipButton() {
    return GestureDetector(
      onTap: _completeOnboarding,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: _buttonColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: _buttonColor.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Skip',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
            SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }

  /// Background Visual with Fallback
  Widget _buildVisualBackground(OnboardingScreenItem item, Color primaryColor) {
    final assetPath = item.platformImage;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Image with high quality rendering filter
        Image.asset(
          assetPath,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stackTrace) {
            if (assetPath.contains('welcome.jpg')) {
              final altPath = assetPath.replaceAll('welcome.jpg', 'welcom.jpg');
              return Image.asset(
                altPath,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, __, ___) =>
                    _buildFallbackVisual(item, primaryColor),
              );
            } else if (assetPath.contains('welcom.jpg')) {
              final altPath = assetPath.replaceAll('welcom.jpg', 'welcome.jpg');
              return Image.asset(
                altPath,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, __, ___) =>
                    _buildFallbackVisual(item, primaryColor),
              );
            }
            return _buildFallbackVisual(item, primaryColor);
          },
        ),

        // Subtle gradient at top to ensure header contrast
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.15),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Graceful Fallback Visual in case image fails to load
  Widget _buildFallbackVisual(OnboardingScreenItem item, Color primaryColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primaryColor.withValues(alpha: 0.12),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.directions_car_filled_rounded,
          size: 120,
          color: primaryColor.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  /// Bottom Curved Card with Title, Subtitle, Dots & Next Button
  Widget _buildBottomCard(Color primaryColor) {
    final screen = _screens[_currentPage];
    final isLast = _currentPage == _screens.length - 1;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Title Line 1 (Dark)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  screen.titlePrefix,
                  key: ValueKey('prefix_$_currentPage'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.5,
                    height: 1.15,
                  ),
                ),
              ),

              // Title Line 2 (Primary Color Highlight)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  screen.titleHighlight,
                  key: ValueKey('highlight_$_currentPage'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 31,
                    fontWeight: FontWeight.w900,
                    color: primaryColor,
                    letterSpacing: -0.5,
                    height: 1.15,
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Description
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    screen.description,
                    key: ValueKey('desc_$_currentPage'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF64748B),
                      height: 1.45,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // 4 Page Indicator Dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_screens.length, (index) {
                  final isActive = index == _currentPage;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: isActive ? 10 : 8,
                    height: isActive ? 10 : 8,
                    decoration: BoxDecoration(
                      color: isActive ? _buttonColor : const Color(0xFFE2E8F0),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              ),

              const SizedBox(height: 22),

              // Next / Get Started Action Button
              Container(
                width: double.infinity,
                height: 54,
                decoration: BoxDecoration(
                  color: _buttonColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _buttonColor.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _onNextPressed,
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isLast ? 'Get Started' : 'Next',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
