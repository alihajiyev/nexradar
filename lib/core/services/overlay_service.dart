import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Dart side of the floating-bubble bridge.
///
/// The bubble itself is drawn by a **native Android service** using
/// `WindowManager` (see `RadarOverlayService.kt`). That is a deliberate
/// architecture choice:
///
/// * the overlay keeps working while the Flutter engine is paused, so the
///   bubble survives the screen turning off;
/// * the 60 FPS interpolation happens on the native render thread with a
///   `Choreographer` callback, so the needle never stutters;
/// * no second Flutter engine means no extra ~60 MB of RSS.
///
/// **Two hosts, one bubble.** Android hides every overlay window the moment the
/// keyguard comes up — `FLAG_SHOW_WHEN_LOCKED` cannot lift a window above the
/// keyguard, it only re-enables one while the keyguard is already occluded — so
/// the lock screen is served by a second host
/// (`NexRadarAccessibilityService`) whose accessibility window sits above it.
/// [lockHudEnabled] reports the driver's grant, [lockHudActive] reports whether
/// that host is actually drawing right now.
///
/// Flutter pushes a tiny JSON payload here roughly once a second (the GPS
/// cadence) and the native view smooths it to 60 FPS.
class OverlayService {
  OverlayService();

  static const MethodChannel _methods = MethodChannel('nexradar/overlay');
  static const EventChannel _eventChannel = EventChannel('nexradar/overlay_events');

  StreamSubscription<dynamic>? _eventSub;
  final StreamController<OverlayEvent> _events =
      StreamController<OverlayEvent>.broadcast();

  bool _running = false;
  bool get isRunning => _running;

  bool get isSupported => !kIsWeb && Platform.isAndroid;

  Stream<OverlayEvent> get events => _events.stream;

  Future<void> init() async {
    if (!isSupported) return;
    _eventSub ??= _eventChannel.receiveBroadcastStream().listen(
      (dynamic raw) {
        if (raw is Map) {
          _events.add(OverlayEvent.fromMap(Map<Object?, Object?>.from(raw)));
        }
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[OverlayService] event error: $e');
      },
    );
  }

  /// `SYSTEM_ALERT_WINDOW` — "Display over other apps". On Android 11+ this is
  /// not a runtime permission: we can only deep-link the user to the settings
  /// page and re-check on resume.
  Future<bool> hasOverlayPermission() async {
    if (!isSupported) return false;
    try {
      final bool? granted = await _methods.invokeMethod<bool>('isPermissionGranted');
      if (granted == true) return true;
    } catch (_) {}
    return Permission.systemAlertWindow.isGranted;
  }

  Future<bool> requestOverlayPermission() async {
    if (!isSupported) return false;
    try {
      final bool? granted =
          await _methods.invokeMethod<bool>('requestPermission');
      return granted ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] requestPermission failed: $e');
      return false;
    }
  }

  /// Starts the foreground service + the draggable bubble.
  Future<bool> show({
    double scale = 1.0,
    bool showRemaining = true,
    double x = 0,
    double y = 0,
  }) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await _methods.invokeMethod<bool>('show', <String, Object?>{
        'scale': scale,
        'showRemaining': showRemaining,
        'x': x,
        'y': y,
      });
      _running = ok ?? false;
      return _running;
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] show failed: $e');
      return false;
    }
  }

  Future<void> hide() async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<bool>('hide');
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] hide failed: $e');
    }
    _running = false;
  }

  /// One state tick → one native frame batch. Cheap: a `Bundle` over the
  /// platform channel, no widget rebuild.
  Future<void> pushState(Map<String, Object?> payload) async {
    if (!isSupported || !_running) return;
    try {
      await _methods.invokeMethod<void>('update', payload);
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] update failed: $e');
    }
  }

  Future<void> setScale(double scale) async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<void>('setScale', <String, Object?>{'scale': scale});
    } catch (_) {}
  }

  // ---------------------------------------------------------- lock-screen HUD

  /// Whether the driver switched the lock-screen HUD on under
  /// *Settings → Accessibility → NexRadar*.
  Future<bool> lockHudEnabled() async {
    if (!isSupported) return false;
    try {
      final bool? enabled = await _methods.invokeMethod<bool>('lockHudEnabled');
      return enabled ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] lockHudEnabled failed: $e');
      return false;
    }
  }

  /// Whether the accessibility host is bound right now — i.e. whether the bubble
  /// is genuinely being drawn above the keyguard.
  Future<bool> lockHudActive() async {
    if (!isSupported) return false;
    try {
      final bool? active = await _methods.invokeMethod<bool>('lockHudActive');
      return active ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Deep-links to the one settings page that can grant an accessibility
  /// service. There is no in-app dialog for this by design.
  Future<void> openLockHudSettings() async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<void>('openLockHudSettings');
    } catch (e) {
      if (kDebugMode) debugPrint('[OverlayService] openLockHudSettings failed: $e');
    }
  }

  /// What the **native** side still believes about the driver's wish.
  ///
  /// "This is a bubble the driver wants" is stored twice: in the app's
  /// preferences (via [show]/[hide]) and in the service's own copy, which is
  /// what lets a reboot, an update or a sticky restart put the bubble back with
  /// no Dart involved. The two can drift apart, and the drift is invisible — a
  /// bubble on screen with nothing computing behind it looks exactly like a
  /// working speedometer reading 0. A cold start therefore reads both stores.
  Future<bool> isDesired() async {
    if (!isSupported) return false;
    try {
      final bool? desired = await _methods.invokeMethod<bool>('isDesired');
      return desired ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> refreshRunningState() async {
    if (!isSupported) return false;
    try {
      final bool? running = await _methods.invokeMethod<bool>('isRunning');
      _running = running ?? false;
    } catch (_) {
      _running = false;
    }
    return _running;
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _events.close();
  }
}

/// What a cold start should do about the bubble — and therefore about the
/// radar pipeline that feeds it.
///
/// The decision is a free function on purpose: it is the whole rule about two
/// stores that must never disagree, so it lives where it can be read and tested
/// on its own instead of as an `if` buried in the bootstrap.
enum BackgroundResume {
  /// Nobody wants a bubble: the driver never switched it on, or he switched it
  /// off from the lock screen. Leave both the window and the pipeline alone.
  none,

  /// The preference says the radar should be running. Make it so — bring the
  /// bubble back if the window is gone and arm the pipeline behind it.
  arm,

  /// A bubble is on screen that the preference has never heard about — what a
  /// lock-screen stop, an update or a process death leaves behind. The driver
  /// can *see* the bubble, so he means it: adopt the native answer and arm the
  /// pipeline, rather than leaving a dial on the lock screen that computes
  /// nothing.
  adopt,
}

/// Reconciles the two stores into one instruction. See [BackgroundResume].
BackgroundResume decideBackgroundResume({
  required bool prefEnabled,
  required bool nativeDesired,
}) {
  if (!prefEnabled && !nativeDesired) return BackgroundResume.none;
  if (nativeDesired && !prefEnabled) return BackgroundResume.adopt;
  return BackgroundResume.arm;
}

/// Things the user does *on the bubble itself*, delivered back to Dart.
class OverlayEvent {
  const OverlayEvent({
    required this.type,
    this.x,
    this.y,
    this.scale,
  });

  /// One of:
  ///
  /// * `addRadar` — the bubble's "+" hotspot, or the media panel's next button
  /// * `pauseWarnings` / `resumeWarnings` — the lock-screen play/pause button
  /// * `toggleVoice` — the media panel's previous button (voice off/on)
  /// * `moved`, `doubleTap`, `tapped`, `dismissed`, `lockHud`
  final String type;
  final double? x;
  final double? y;
  final double? scale;

  bool get isReportRequest => type == 'addRadar';

  /// The lock-screen panel's play/pause button.
  ///
  /// A *request*, not a command: Dart owns the silence window (it is the layer
  /// that beeps), applies it and pushes the effective value back to the panel.
  bool get isSilenceRequest => type == 'pauseWarnings';

  bool get isResumeRequest => type == 'resumeWarnings';

  /// The media panel's previous button: voice guidance off/on in one tap.
  bool get isVoiceToggle => type == 'toggleVoice';

  static OverlayEvent fromMap(Map<Object?, Object?> map) => OverlayEvent(
        type: (map['type'] as String?) ?? 'unknown',
        x: (map['x'] as num?)?.toDouble(),
        y: (map['y'] as num?)?.toDouble(),
        scale: (map['scale'] as num?)?.toDouble(),
      );

  @override
  String toString() => 'OverlayEvent($type, x=$x, y=$y, scale=$scale)';
}
