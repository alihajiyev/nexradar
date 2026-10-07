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
/// * `FLAG_SHOW_WHEN_LOCKED` + a `TYPE_APPLICATION_OVERLAY` window lets the
///   bubble render **on the lock screen** without unlocking the device;
/// * the 60 FPS interpolation happens on the native render thread with a
///   `Choreographer` callback, so the needle never stutters;
/// * no second Flutter engine means no extra ~60 MB of RSS.
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

/// Things the user does *on the bubble itself*, delivered back to Dart.
class OverlayEvent {
  const OverlayEvent({
    required this.type,
    this.x,
    this.y,
    this.scale,
  });

  /// `addRadar` | `moved` | `doubleTap` | `tapped` | `dismissed`
  final String type;
  final double? x;
  final double? y;
  final double? scale;

  bool get isReportRequest => type == 'addRadar';

  static OverlayEvent fromMap(Map<Object?, Object?> map) => OverlayEvent(
        type: (map['type'] as String?) ?? 'unknown',
        x: (map['x'] as num?)?.toDouble(),
        y: (map['y'] as num?)?.toDouble(),
        scale: (map['scale'] as num?)?.toDouble(),
      );

  @override
  String toString() => 'OverlayEvent($type, x=$x, y=$y, scale=$scale)';
}
