import 'package:flutter/material.dart';

/// The kinds of speed enforcement NexRadar knows about.
///
/// [wire] is what gets written to SQLite / uploaded to the community feed, so it
/// must stay stable even if the labels change.
enum CameraType {
  fixed(
    wire: 'fixed',
    labelAz: 'Sabit radar',
    labelTr: 'Sabit radar',
    labelEn: 'Fixed camera',
    icon: Icons.photo_camera_outlined,
    color: Color(0xFFFFA726),
  ),
  mobile(
    wire: 'mobile',
    labelAz: 'Mobil YPX',
    labelTr: 'Mobil radar',
    labelEn: 'Mobile unit',
    icon: Icons.local_police_outlined,
    color: Color(0xFFFF5252),
  ),
  redLight(
    wire: 'red_light',
    labelAz: 'İşıqfor radarı',
    labelTr: 'Kırmızı ışık radarı',
    labelEn: 'Red light camera',
    icon: Icons.traffic_outlined,
    color: Color(0xFF7E57C2),
  ),
  averageSpeed(
    wire: 'average_speed',
    labelAz: 'Orta sürət ölçmə',
    labelTr: 'Ortalama hız ölçümü',
    labelEn: 'Average speed check',
    icon: Icons.timeline_outlined,
    color: Color(0xFF26C6DA),
  );

  const CameraType({
    required this.wire,
    required this.labelAz,
    required this.labelTr,
    required this.labelEn,
    required this.icon,
    required this.color,
  });

  final String wire;
  final String labelAz;
  final String labelTr;
  final String labelEn;
  final IconData icon;
  final Color color;

  static CameraType fromWire(String? wire) {
    if (wire == null) return CameraType.fixed;
    for (final CameraType t in CameraType.values) {
      if (t.wire == wire) return t;
    }
    return CameraType.fixed;
  }

  /// Temporary, community-sourced reports are rendered as [CameraType.mobile]
  /// but we still keep them distinct in the UI.
  bool get isCommunityReport => this == CameraType.mobile;

  String label(String languageCode) {
    switch (languageCode) {
      case 'az':
        return labelAz;
      case 'tr':
        return labelTr;
      default:
        return labelEn;
    }
  }
}
