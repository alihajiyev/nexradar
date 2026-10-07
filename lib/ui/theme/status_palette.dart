import 'package:flutter/material.dart';

import '../../core/constants/camera_types.dart';
import '../../models/vehicle_state.dart';
import 'app_theme.dart';

/// Maps the two domain enums that drive colour (`DrivingStatus`, `CameraType`)
/// onto the NexRadar palette.
///
/// The mapping lives here — not on the enums — so the models stay free of
/// Flutter and the UI stays free of ad-hoc hex values.
abstract final class StatusPalette {
  static Color of(DrivingStatus status) => switch (status) {
        DrivingStatus.idle => NexColors.primary,
        DrivingStatus.approaching => NexColors.amber,
        DrivingStatus.warning => NexColors.danger,
      };

  static Color ofCamera(CameraType type) => switch (type) {
        CameraType.fixed => NexColors.amber,
        CameraType.mobile => NexColors.danger,
        CameraType.redLight => const Color(0xFFB08CFF),
        CameraType.averageSpeed => NexColors.cyan,
      };

  /// Human label for a driving status, in Azerbaijani.
  static String label(DrivingStatus status) => switch (status) {
        DrivingStatus.idle => 'Yol təmizdir',
        DrivingStatus.approaching => 'Radar yaxınlaşır',
        DrivingStatus.warning => 'Diqqət — radar!',
      };
}

/// Small, dependency-free formatters. Keeping them in one place means the gauge,
/// the bubble and the radar list can never disagree about "1.2 km" vs "1200 m".
abstract final class Fmt {
  /// `<1000 m` → "420 m", otherwise "1.2 km".
  static String distance(double? meters) {
    if (meters == null || meters.isNaN) return '—';
    if (meters < 1000) return '${meters.round()} m';
    final double km = meters / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  /// Compact distance used inside the floating bubble ("450 m" / "1.2 km").
  static String distanceShort(double? meters) => distance(meters);

  static String speed(double kmh, {required bool mph}) {
    final double value = mph ? kmh / 1.609344 : kmh;
    return value.round().toString();
  }

  static String unitLabel({required bool mph}) => mph ? 'mph' : 'km/s';

  static String limit({required int? kmh, required bool mph}) {
    if (kmh == null || kmh <= 0) return '—';
    return speed(kmh.toDouble(), mph: mph);
  }

  static String eta(int? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    if (seconds < 60) return '${seconds}s';
    final int minutes = (seconds / 60).round();
    return '$minutes dəq';
  }

  /// "indi", "12 dəq əvvəl", "3 saat əvvəl" …
  static String ago(DateTime? at) {
    if (at == null) return 'heç vaxt';
    final Duration d = DateTime.now().difference(at);
    if (d.isNegative) return 'indi';
    if (d.inMinutes < 1) return 'indi';
    if (d.inMinutes < 60) return '${d.inMinutes} dəq əvvəl';
    if (d.inHours < 24) return '${d.inHours} saat əvvəl';
    return '${d.inDays} gün əvvəl';
  }

  /// Eight-point compass name for a heading
  /// (`Şimal`, `Şimal-Şərq`, `Şərq`, …).
  static String compass(double degrees) {
    const List<String> points = <String>[
      'Şimal',
      'Şimal-Şərq',
      'Şərq',
      'Cənub-Şərq',
      'Cənub',
      'Cənub-Qərb',
      'Qərb',
      'Şimal-Qərb',
    ];
    final double normalized = ((degrees % 360) + 360) % 360;
    final int index = ((normalized / 45) + 0.5).floor() % 8;
    return points[index];
  }

  static String accuracy(double meters) {
    if (meters <= 0) return '—';
    return '±${meters.round()} m';
  }
}
