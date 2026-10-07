/// Central, single source of truth for every tunable number in NexRadar.
///
/// Nothing in the app should hard-code a distance, angle or duration — the
/// constants below are what the settings screen and the engine read.
class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------- identity
  static const String appName = 'NexRadar';
  static const String appTagline = 'Arxa fonda işləyən radar & sürət HUD';
  static const String appVersion = '1.3.0';

  // -------------------------------------------------------------- persistence
  static const String dbName = 'nex_radar.db';
  static const int dbVersion = 1;

  static const String tableCameras = 'speed_camera';
  static const String tablePendingReports = 'pending_report';
  static const String tableSyncMeta = 'sync_meta';

  // ------------------------------------------------------------------- engine
  /// The radar horizon, in meters.
  ///
  /// NexRadar always looks **exactly** this far ahead and reports the nearest
  /// camera inside it. This is deliberately not a setting: the driver asked for
  /// a fixed 5 km picture — not less, not more — so the bubble and the
  /// lock-screen card always mean the same thing.
  static const double radarHorizonMeters = 5000.0;

  /// |θ_heading - θ_camera| <= tolerance ⇒ the camera is a real forward threat.
  /// Everything else is oncoming traffic / perpendicular streets and is dropped.
  static const double angularToleranceDegrees = 45.0;

  /// Extra slack used when we only know where the camera is (no facing angle).
  static const double approachToleranceDegrees = 55.0;

  // --------------------------------------------------------- approach ladder
  /// The approach ladder, in meters — one source of truth for the bubble's
  /// colour, the beeps and the spoken announcements.
  ///
  /// * 1000 m — the bubble turns amber and the first sentence plays;
  /// * 500 m — an audible tick and a second sentence;
  /// * 200 m — red flasher, alarm, "slow down" sentence.
  ///
  /// Listed from far to near. Each gate fires **exactly once per approach and
  /// only when it is crossed**: a radar that shows up already inside a gate was
  /// passed before we knew about it, so it is recorded silently instead of
  /// announced. That is what removes the old "radar 0 metres away" surprise
  /// when a community report popped up next to the car.
  static const List<double> approachGatesMeters = <double>[1000.0, 500.0, 200.0];

  /// The amber gate (first of [approachGatesMeters]).
  static const double gateFarMeters = 1000.0;

  /// The beep gate.
  static const double gateMidMeters = 500.0;

  /// The red-flasher / alarm gate.
  static const double gateNearMeters = 200.0;

  /// Do not repeat the same sentence faster than this.
  static const Duration voiceCooldown = Duration(seconds: 9);

  /// Kill switch: never queue more than N sentences in a row.
  static const Duration voiceGlobalCooldown = Duration(seconds: 3);

  // ------------------------------------------------------------ beep / alarm
  static const Duration beepCooldown = Duration(milliseconds: 900);
  static const Duration alarmRepeatInterval = Duration(milliseconds: 1600);

  // ----------------------------------------------------------- crowdsourcing
  /// A community "mobile YPX" report stays valid for two hours.
  static const Duration temporaryRadarTtl = Duration(hours: 2);

  /// How often the live community feed is polled while driving.
  static const Duration communityPollInterval = Duration(seconds: 45);

  // --------------------------------------------------------- camera cache db
  /// Re-read the local cache when we moved this far or this much time passed.
  static const double cameraRefreshMoveMeters = 60.0;
  static const Duration cameraRefreshInterval = Duration(seconds: 12);

  /// Temporary reports older than this are pruned from SQLite.
  static const Duration temporaryPurgeAfter = Duration(hours: 3);

  // ---------------------------------------------------------- speed smoothing
  /// Time constant of the exponential smoother that turns the 1 Hz GPS chip
  /// into a 60 FPS fluid needle. Bigger = smoother but lazier.
  static const double speedSmoothingTauSeconds = 0.42;

  /// Hard clamp so a bad fix can never paint a 900 km/h needle.
  static const double maxDisplayKmh = 320.0;

  /// A fix older than this is considered lost.
  static const Duration gpsStaleAfter = Duration(seconds: 5);

  /// Stop moving below this (GPS jitter at standstill reads 1-3 km/h).
  static const double speedDeadbandKmh = 2.4;

  // --------------------------------------------------------------- defaults
  static const double defaultSpeedLimitKmh = 60.0;

  /// Sent to the native overlay when no limit is known for the threat.
  static const int unknownLimit = -1;

  // -------------------------------------------------------------- osm / sync
  static const List<String> overpassEndpoints = <String>[
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  static const Duration overpassTimeout = Duration(seconds: 40);

  /// Shrink the Overpass window above this so the query never explodes.
  static const double maxSyncRadiusMeters = 60000.0;
  static const double defaultSyncRadiusMeters = 25000.0;

  // ------------------------------------------------------------ preference keys
  static const String prefOverlayEnabled = 'overlay_enabled';
  static const String prefVoiceEnabled = 'voice_enabled';
  static const String prefBeepEnabled = 'beep_enabled';
  static const String prefLanguage = 'voice_language';
  static const String prefAngularTolerance = 'angular_tolerance';
  static const String prefUnitsMph = 'units_mph';
  static const String prefShowRemaining = 'overlay_show_remaining';
  static const String prefFirebaseUrl = 'crowd_firebase_url';
  static const String prefSyncRadius = 'sync_radius';
  static const String prefLastSync = 'last_sync_epoch';
  static const String prefOverlayScale = 'overlay_scale';
  static const String prefOverlayX = 'overlay_x';
  static const String prefOverlayY = 'overlay_y';
  static const String prefOnboarded = 'onboarding_completed';
  static const String prefUpdateRepo = 'update_repo';
  static const String prefAutoUpdateCheck = 'auto_update_check';
  static const String prefLastUpdateCheck = 'last_update_check';
  static const String prefPendingUpdate = 'pending_update_version';
  static const String prefLogExpanded = 'log_expanded';

  // ------------------------------------------------------------------ route
  /// How far off the driven line a radar may sit before it is treated as "not
  /// on my road" and dropped.
  ///
  /// Generous on purpose: a community report is eyeballed within ~20 m and a GPS
  /// fix is worth another 10 m, so a tight corridor would silently lose real
  /// radars. 150 m is enough to reject a camera on a parallel street or on the
  /// far side of an interchange while keeping every radar on the carriageway.
  static const double routeCorridorToleranceMeters = 150.0;

  /// Spacing of the retained GPS track, and its total length. The track is the
  /// "where have I been" half of the corridor: long enough to average out the
  /// GPS jitter, short enough to forget a road we left a while ago.
  static const double routeTrackSpacingMeters = 15.0;
  static const double routeTrackMaxMeters = 1200.0;

  /// A course is only trusted once the track is at least this long: below it,
  /// the raw fix-to-fix heading is the better estimate.
  static const double routeCourseMinTrackMeters = 60.0;

  // ---------------------------------------------------- average-speed sections
  /// A section closes once the driver has driven this far past its entry marker.
  /// OSM gives a section as a single node, so there is no real exit to wait for;
  /// this is the point where keeping the clock running would be a lie.
  static const double averageSectionMaxMeters = 1200.0;

  /// The average is meaningless before this much of the section has been driven:
  /// five seconds of GPS noise is not a speed.
  static const double averageSectionMinMeters = 60.0;
  static const int averageSectionMinSeconds = 8;

  /// Do not nag about the same section average more often than this.
  static const Duration averageSectionWarnCooldown = Duration(seconds: 30);

  // ----------------------------------------------------------------- geometry
  /// Meters per degree of latitude (good enough for city-scale filtering).
  static const double metersPerDegreeLat = 111320.0;
}
