import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/constants/app_constants.dart';
import 'core/database/camera_repository.dart';
import 'core/location/location_service.dart';
import 'core/services/alert_service.dart';
import 'core/services/crowdsourced_radar_service.dart';
import 'core/services/osm_sync_service.dart';
import 'core/services/overlay_service.dart';
import 'core/services/radar_engine.dart';
import 'core/services/settings_service.dart';
import 'core/services/tts_service.dart';
import 'core/services/update_service.dart';
import 'ui/theme/app_theme.dart';
import 'views/home_shell.dart';
import 'views/onboarding/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await applyEdgeToEdgeChrome();

  final AppServices services = AppServices();
  await services.bootstrap();
  runApp(NexRadarApp(services: services));
}

/// Edge-to-edge styling, applied on a best-effort basis.
///
/// The engine is created by the application, before any activity is attached to
/// it, so this call finds no platform handler in the background and throws. That
/// is expected — the styling only means anything once a view exists, and
/// [_SystemChromeBinder] re-applies it the moment one does.
Future<void> applyEdgeToEdgeChrome() async {
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: NexColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  } catch (e) {
    if (kDebugMode) debugPrint('[main] system chrome not available yet: $e');
  }
}

/// Tiny hand-rolled service locator.
///
/// A full DI container would be overkill for nine singletons, and keeping the
/// wiring in one readable place makes the boot order obvious: settings first
/// (everything reads them), then the speech/audio engines, then the overlay
/// bridge, and only then the engine that ties them together.
class AppServices {
  final SettingsService settings = SettingsService.instance;
  late final CameraRepository repository;
  late final LocationService locationService;
  late final TtsService tts;
  late final AlertService alerts;
  late final OverlayService overlay;
  late final CrowdsourcedRadarService crowd;
  late final OsmSyncService osmSync;
  late final UpdateService updates;
  late final RadarEngine engine;

  StreamSubscription<OverlayEvent>? _overlayEvents;
  bool _ready = false;
  bool get isReady => _ready;

  /// One-shot user-facing messages. The shell listens and shows a snackbar.
  final ValueNotifier<String?> lastNotice = ValueNotifier<String?>(null);

  /// Non-null while a newer GitHub release is waiting to be installed.
  final ValueNotifier<ReleaseInfo?> availableUpdate =
      ValueNotifier<ReleaseInfo?>(null);

  Future<void> bootstrap() async {
    await settings.load();

    repository = CameraRepository();
    locationService = LocationService();
    tts = TtsService();
    alerts = AlertService();
    overlay = OverlayService();
    crowd = CrowdsourcedRadarService(
      repository: repository,
      settings: settings,
    );
    osmSync = OsmSyncService(repository: repository);
    updates = UpdateService(settings: settings);
    engine = RadarEngine(
      repository: repository,
      locationService: locationService,
      settings: settings,
      tts: tts,
      alerts: alerts,
      overlay: overlay,
      crowd: crowd,
      osmSync: osmSync,
    );

    // Warm the audio + voice engines on startup; both are cheap but a first
    // call inside the alert ladder would be audible as latency.
    await alerts.init();
    await tts.init(language: settings.language);

    await overlay.init();
    _overlayEvents = overlay.events.listen(_onOverlayEvent);

    // Housekeeping: drop expired community reports from previous sessions.
    unawaited(repository.purgeExpiredTemporary());

    await overlay.refreshRunningState();
    settings.addListener(_onSettingsChanged);
    _ready = true;

    // Background-first: the bubble outlives the dashboard. A process that comes
    // back with no UI at all — the overlay service restarting after the task was
    // swiped away, or a sticky restart after process death — has to put the
    // radar pipeline back to work by itself, because by then the driver is
    // already on the road.
    if (settings.overlayEnabled) {
      unawaited(resumeInBackground());
    }

    // A cold start is the natural moment to look for a new build: the driver is
    // stationary, the screen is on, and a failure costs nothing.
    if (settings.autoUpdateCheck) {
      unawaited(checkForUpdates(silent: true));
    }
  }

  /// Queries GitHub Releases. [silent] keeps a routine startup check from
  /// interrupting the driver with a snackbar when it fails.
  Future<UpdateCheckResult> checkForUpdates({bool silent = false}) async {
    final UpdateCheckResult result = await updates.check();
    await settings.markUpdateChecked();
    availableUpdate.value = result.hasUpdate ? result.release : null;
    if (!silent || result.status == UpdateStatus.failed) {
      lastNotice.value = result.message;
    }
    return result;
  }

  void _onSettingsChanged() {
    unawaited(tts.setLanguage(settings.language));
  }

  void _onOverlayEvent(OverlayEvent event) {
    switch (event.type) {
      case 'addRadar':
        unawaited(_reportFromBubble());
      case 'doubleTap':
        if (event.scale != null) {
          unawaited(settings.setOverlayScale(event.scale!));
        }
      case 'dismissed':
        unawaited(settings.setOverlayEnabled(false));
      case 'moved':
        if (event.x != null && event.y != null) {
          unawaited(settings.setOverlayPosition(event.x!, event.y!));
        }
    }
  }

  Future<void> _reportFromBubble() async {
    final ReportResult result = await engine.reportTemporaryRadar();
    lastNotice.value = result.message;
  }

  /// Starts/stops the whole pipeline together with the native bubble.
  Future<bool> setOverlayEnabled(bool enabled) async {
    if (!overlay.isSupported) {
      lastNotice.value = 'Yüzen baloncuk yalnız Android-də dəstəklənir.';
      await settings.setOverlayEnabled(false);
      return false;
    }

    if (!enabled) {
      await overlay.hide();
      await settings.setOverlayEnabled(false);
      return false;
    }

    final bool granted = await overlay.hasOverlayPermission() ||
        await overlay.requestOverlayPermission();
    if (!granted) {
      lastNotice.value =
          'Zəhmət olmasa "Digər tətbiqlərin üzərində göstər" icazəsini verin.';
      await settings.setOverlayEnabled(false);
      return false;
    }

    final bool shown = await overlay.show(
      scale: settings.overlayScale,
      showRemaining: settings.showRemaining,
    );
    await settings.setOverlayEnabled(shown);
    if (!shown) {
      lastNotice.value = 'Baloncuk başladıla bilmədi.';
    }
    return shown;
  }

  /// Puts the radar pipeline back to work without any UI attached.
  ///
  /// Safe to call more than once: everything here is idempotent, and a failure
  /// (permission revoked while the app was closed, GPS off) is silent by design
  /// — there is nobody to show a snackbar to.
  Future<void> resumeInBackground() async {
    if (!settings.overlayEnabled) return;
    try {
      await overlay.refreshRunningState();
      if (!await locationService.hasPermission()) return;
      if (!engine.isRunning) await engine.start(background: true);
      if (!overlay.isRunning) {
        await overlay.show(
          scale: settings.overlayScale,
          showRemaining: settings.showRemaining,
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AppServices] background resume failed: $e');
    }
  }

  /// Starts the location pipeline + the bubble in one gesture.
  Future<void> startDriving() async {
    final LocationPermissionResult permission =
        await locationService.ensurePermissions();
    if (!permission.isUsable) {
      lastNotice.value = permission.message;
      return;
    }
    await engine.start(background: true);
    if (settings.overlayEnabled) {
      await overlay.show(
        scale: settings.overlayScale,
        showRemaining: settings.showRemaining,
      );
    }
    lastNotice.value = permission.message;
  }

  Future<void> stopDriving() async {
    await engine.stop();
    await overlay.hide();
    await settings.setOverlayEnabled(false);
  }

  Future<void> dispose() async {
    settings.removeListener(_onSettingsChanged);
    await _overlayEvents?.cancel();
    await engine.dispose();
    await overlay.dispose();
    await tts.dispose();
    await alerts.dispose();
    await    locationService.dispose();
    crowd.dispose();
    osmSync.dispose();
    updates.dispose();
    availableUpdate.dispose();
  }
}

/// Re-applies the edge-to-edge chrome whenever a view exists, and re-checks the
/// background state whenever the driver comes back.
class _SystemChromeBinder extends StatefulWidget {
  const _SystemChromeBinder({required this.child});

  final Widget child;

  @override
  State<_SystemChromeBinder> createState() => _SystemChromeBinderState();
}

class _SystemChromeBinderState extends State<_SystemChromeBinder>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(applyEdgeToEdgeChrome());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(applyEdgeToEdgeChrome());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class NexRadarApp extends StatelessWidget {
  const NexRadarApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return _SystemChromeBinder(
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: NexTheme.dark(),
        home: NexRadarScope(
          services: services,
          child: _RootGate(services: services),
        ),
      ),
    );
  }
}

/// Chooses between the first-run flow and the app itself, and re-evaluates as
/// soon as onboarding writes its flag.
class _RootGate extends StatelessWidget {
  const _RootGate({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: services.settings,
      builder: (BuildContext context, _) {
        if (!services.settings.onboarded) {
          return OnboardingScreen(
            services: services,
            onFinished: () {},
          );
        }
        return HomeShell(services: services);
      },
    );
  }
}

/// Small helper used by the views to read the app's services from the tree.
extension ServicesContext on BuildContext {
  AppServices get services => NexRadarScope.of(this);
}

class NexRadarScope extends InheritedWidget {
  const NexRadarScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final NexRadarScope? scope =
        context.dependOnInheritedWidgetOfExactType<NexRadarScope>();
    assert(scope != null, 'NexRadarScope is missing above this widget');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(NexRadarScope oldWidget) =>
      oldWidget.services != services;
}

/// Kept for tests / debugging: prints the boot state.
@visibleForTesting
String describeServices(AppServices services) =>
    'NexRadar ready=${services.isReady} '
    'overlay=${services.overlay.isSupported} '
    'voice=${services.tts.effectiveLanguage}';
