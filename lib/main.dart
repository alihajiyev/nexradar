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
import 'core/services/warning_silence.dart';
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
    //
    // Always asked, never gated on the preference here: "should this process be
    // driving?" is decided in one place, from both stores (see
    // [resumeInBackground]), and a bubble that is already on screen counts as a
    // yes even when the preference says nothing — otherwise the driver gets a
    // lock screen that shows a dial computing nothing.
    unawaited(resumeInBackground());

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
      case 'pauseWarnings':
        unawaited(_silenceWarnings());
      case 'resumeWarnings':
        unawaited(engine.resumeWarnings(byUser: true));
      case 'toggleVoice':
        unawaited(_toggleVoice());
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

  /// The lock-screen pause button: mute the warnings for the bounded window.
  ///
  /// Reported back to the driver only when there is a UI to report to — the
  /// lock screen is usually the only thing on screen at the time, and the media
  /// card itself shows the countdown, which is the better answer anyway.
  Future<void> _silenceWarnings() async {
    await engine.silenceWarnings();
    lastNotice.value = 'Sükut rejimi: ${WarningSilence.window.inMinutes} dəqiqə';
  }

  /// The lock-screen previous button: voice guidance off/on without unlocking.
  Future<void> _toggleVoice() async {
    await settings.setVoiceEnabled(!settings.voiceEnabled);
    lastNotice.value = settings.voiceEnabled
        ? 'Səsli xəbərdarlıq açıldı'
        : 'Səsli xəbərdarlıq bağlandı';
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

    // Either grant can carry the bubble: "display over other apps" for the
    // ordinary window, and the accessibility grant for the lock-screen host,
    // which is the window the keyguard cannot hide. Asking for the overlay grant
    // when the driver has already given the other one would send him to a
    // settings page he does not need.
    final bool granted = await overlay.hasOverlayPermission() ||
        await overlay.lockHudEnabled() ||
        await overlay.requestOverlayPermission();
    if (!granted) {
      lastNotice.value =
          'Zəhmət olmasa "Digər tətbiqlərin üzərində göstər" icazəsini verin.';
      await settings.setOverlayEnabled(false);
      return false;
    }

    // The bubble and the radar are one switch in the driver's head: a dial that
    // floats over the map showing a frozen 0 km/s is indistinguishable from a
    // dead app, and on the lock screen it is the *only* thing he can look at.
    // Turning the bubble on therefore arms the pipeline behind it — which is
    // what the lock-screen panel reports from, so "it works on the lock screen"
    // no longer depends on having pressed the right one of two buttons.
    final bool armed = await _armRadar();

    final bool shown = await overlay.show(
      scale: settings.overlayScale,
      showRemaining: settings.showRemaining,
    );
    await settings.setOverlayEnabled(shown);
    if (!shown) {
      lastNotice.value = 'Baloncuk başladıla bilmədi.';
    } else if (!armed) {
      lastNotice.value =
          'Baloncuk açıqdır, amma radar dayanır: konum izni lazımdır.';
    }
    return shown;
  }

  /// Starts the radar pipeline if it is not running, and says whether it is up.
  ///
  /// Separate from [startDriving] because the caller already knows what it is
  /// turning on: this only reports the one reason it cannot start — the location
  /// grant — so the driver gets a sentence he can act on instead of a silent
  /// bubble that shows nothing.
  Future<bool> _armRadar() async {
    if (engine.isRunning) return true;
    if (!await locationService.hasPermission()) return false;
    await engine.start(background: true);
    return engine.isRunning;
  }

  /// Puts the radar pipeline back to work without any UI attached.
  ///
  /// Safe to call more than once: everything here is idempotent, and a failure
  /// (permission revoked while the app was closed, GPS off) is silent by design
  /// — there is nobody to show a snackbar to.
  Future<void> resumeInBackground() async {
    await overlay.refreshRunningState();

    // Whether the radar should be running is recorded twice — in the app's
    // preferences and in the native service, which keeps its own copy so a
    // reboot can restore the bubble on its own. A process death, an update or a
    // stop from the lock screen can leave the two disagreeing, and the result is
    // the worst possible state: a bubble on the lock screen that computes
    // nothing, which a driver reads as "the app closed". So both stores are
    // consulted, and [BackgroundResume.adopt] trusts the bubble he can see.
    final BackgroundResume intent = decideBackgroundResume(
      prefEnabled: settings.overlayEnabled,
      nativeDesired: await overlay.isDesired(),
    );
    if (intent == BackgroundResume.none) return;

    try {
      if (intent == BackgroundResume.adopt) {
        await settings.setOverlayEnabled(true);
      }
      // A bubble with no fix is honest only while there is somewhere to get one.
      // The grant is checked here rather than at the switch because it can be
      // revoked between two launches.
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
