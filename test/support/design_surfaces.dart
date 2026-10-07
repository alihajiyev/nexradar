import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nex_radar/dev/preview_main.dart';
import 'package:nex_radar/ui/theme/app_theme.dart';

/// A Pixel-class viewport — the smallest screen NexRadar must survive.
const Size phoneViewport = Size(390, 844);

/// The real Inter faces are bundled, but the test runner only knows about them
/// if we hand them to the engine explicitly. Without this the goldens would be
/// rendered in the placeholder test font.
Future<void> loadDesignFonts() async {
  const Map<String, List<String>> families = <String, List<String>>{
    'Inter': <String>['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'],
    'InterDisplay': <String>['SemiBold', 'Bold'],
  };
  for (final MapEntry<String, List<String>> family in families.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String weight in family.value) {
      loader.addFont(
        rootBundle.load('assets/fonts/${family.key}-$weight.ttf'),
      );
    }
    await loader.load();
  }
}

/// Every composition the design system ships, rendered with canned data.
final Map<String, Widget Function()> designSurfaces = <String, Widget Function()>{
  'dashboard': () => const DashboardMock(),
  'gauges': () => const GaugeStates(),
  'radars': () => const RadarsMock(),
  'settings': () => const SettingsMock(),
  'bubble': () => const BubbleMock(),
};

/// Wraps a surface in the app chrome at a fixed viewport.
Widget designHost(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: NexTheme.dark(),
    home: Scaffold(
      backgroundColor: NexColors.background,
      body: child,
    ),
  );
}
