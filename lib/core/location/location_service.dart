import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants/app_constants.dart';

/// Everything that talks to the GPS chip.
///
/// The stream is configured with a **foreground notification**, which is what
/// keeps the process (and therefore the floating bubble, the TTS engine and the
/// headline `ON_PAUSE` Dart isolate) alive while the phone is locked or another
/// app is on screen. Android will not deliver background location without it.
class LocationService {
  LocationService();

  StreamSubscription<Position>? _sub;

  /// Asks for `ACCESS_FINE_LOCATION` → `ACCESS_BACKGROUND_LOCATION` in the
  /// order Android requires (background must be requested *after* foreground,
  /// and on Android 11+ it opens the settings page instead of a dialog).
  Future<LocationPermissionResult> ensurePermissions() async {
    if (kIsWeb) return LocationPermissionResult.unsupported;

    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return LocationPermissionResult.serviceDisabled;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return LocationPermissionResult.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionResult.deniedForever;
    }

    // Background is a *separate* grant; without it the bubble freezes as soon
    // as the screen goes off on many OEM builds.
    if (!kIsWeb && permission == LocationPermission.whileInUse) {
      final PermissionStatus always = await Permission.locationAlways.request();
      if (always.isGranted) {
        return LocationPermissionResult.alwaysGranted;
      }
      return LocationPermissionResult.whileInUse;
    }

    return permission == LocationPermission.always
        ? LocationPermissionResult.alwaysGranted
        : LocationPermissionResult.whileInUse;
  }

  bool get isBackgroundCapable =>
      !kIsWeb && Platform.isAndroid;

  /// Silent check — never shows a dialog. Used by the onboarding flow, which
  /// needs to render the current grant state on every resume.
  Future<bool> hasPermission() async {
    if (kIsWeb) return false;
    try {
      final LocationPermission p = await Geolocator.checkPermission();
      return p == LocationPermission.always || p == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// True when the device's location toggle is on at the OS level.
  Future<bool> locationServiceEnabled() async {
    if (kIsWeb) return false;
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return false;
    }
  }

  LocationSettings settings({bool background = true}) {
    if (kIsWeb || !Platform.isAndroid) {
      return const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: const Duration(milliseconds: 1000),
      // Fused provider gives better speed/heading than the raw GPS chip.
      forceLocationManager: false,
      foregroundNotificationConfig: background
          ? ForegroundNotificationConfig(
              notificationTitle: '${AppConstants.appName} aktivdir',
              notificationText:
                  'Sürət və radar nəzarəti arxa fonda işləyir',
              notificationChannelName: 'NexRadar xidməti',
              enableWakeLock: true,
              setOngoing: true,
              notificationIcon:
                  const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
            )
          : null,
    );
  }

  /// Live fixes. Single-subscription: the engine owns exactly one consumer.
  Stream<Position> positions({bool background = true}) {
    _sub?.cancel();
    return Geolocator.getPositionStream(locationSettings: settings(background: background))
        .handleError((Object e, StackTrace s) {
      if (kDebugMode) {
        debugPrint('[LocationService] stream error: $e');
      }
    });
  }

  Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// Convenience: km/h from a [Position] (`speed` is m/s on every platform).
  static double kmh(Position p) {
    final double v = p.speed;
    if (v.isNaN || v.isInfinite || v < 0) return 0;
    return v * 3.6;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Opens the system location settings page (used when the user turned GPS
  /// off entirely).
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}

enum LocationPermissionResult {
  alwaysGranted,
  whileInUse,
  denied,
  deniedForever,
  serviceDisabled,
  unsupported;

  bool get isUsable =>
      this == LocationPermissionResult.alwaysGranted ||
      this == LocationPermissionResult.whileInUse;

  String get message {
    switch (this) {
      case LocationPermissionResult.alwaysGranted:
        return 'Konum izni tam verildi (arxa fon daxil).';
      case LocationPermissionResult.whileInUse:
        return 'Yalnız tətbiq açıq ikən konum. Arxa fon üçün "Həmişə icazə ver" seçin.';
      case LocationPermissionResult.denied:
        return 'Konum izni verilmədi.';
      case LocationPermissionResult.deniedForever:
        return 'Konum izni birdəfəlik bloklandı. Tənzimləmələrdən açın.';
      case LocationPermissionResult.serviceDisabled:
        return 'GPS/qurğu qurğusu söndürülüb.';
      case LocationPermissionResult.unsupported:
        return 'Bu platformada konum dəstəklənmir.';
    }
  }
}
