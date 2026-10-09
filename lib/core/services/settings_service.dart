import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import 'warning_silence.dart';

/// All user-facing preferences, persisted through SharedPreferences and exposed
/// as [ValueNotifier]s so the UI and the engine stay in sync live.
class SettingsService extends ChangeNotifier {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  SharedPreferences? _prefs;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  // ------------------------------------------------------------------ values
  bool _overlayEnabled = false;
  bool _voiceEnabled = true;
  bool _beepEnabled = true;

  /// The bounded silence window ("Sükut rejimi"). See [WarningSilence].
  WarningSilence _silence = WarningSilence.off;
  String _language = 'az-AZ';
  double _angularTolerance = AppConstants.angularToleranceDegrees;
  bool _useMph = false;
  bool _showRemaining = true;
  double _overlayScale = 1.0;
  double _syncRadius = AppConstants.defaultSyncRadiusMeters;
  String _firebaseUrl = '';
  DateTime? _lastSync;
  bool _onboarded = false;
  bool _logExpanded = false;
  String _updateRepo = '';
  bool _autoUpdateCheck = true;
  DateTime? _lastUpdateCheck;

  bool get overlayEnabled => _overlayEnabled;
  bool get voiceEnabled => _voiceEnabled;
  bool get beepEnabled => _beepEnabled;

  /// The silence window, shared by the engine, the lock-screen media panel, the
  /// floating bubble and the diagnostics screen.
  WarningSilence get silence => _silence;
  bool get warningsPaused => _silence.isActive;
  bool get showRemaining => _showRemaining;
  bool get useMph => _useMph;
  String get language => _language;
  String get languageShort => _language.split('-').first;
  double get angularTolerance => _angularTolerance;

  /// The fixed radar horizon. Exposed here so the UI has one place to read it
  /// from, but it is a constant — the driver asked for exactly 5 km.
  double get radarHorizon => AppConstants.radarHorizonMeters;
  double get overlayScale => _overlayScale;
  double get syncRadius => _syncRadius;
  String get firebaseUrl => _firebaseUrl;
  DateTime? get lastSync => _lastSync;

  /// True once the driver has walked through the intro + permission flow.
  bool get onboarded => _onboarded;

  /// Whether the dashboard's live event log is expanded.
  bool get logExpanded => _logExpanded;

  /// `owner/name` of the GitHub repository that publishes the release APKs.
  String get updateRepo => _updateRepo;

  /// Check GitHub for a new release on every cold start.
  bool get autoUpdateCheck => _autoUpdateCheck;
  DateTime? get lastUpdateCheck => _lastUpdateCheck;

  String get speedUnit => _useMph ? 'mph' : 'km/s';

  /// Display helper: converts the stored km/h value into the active unit.
  double displaySpeed(double kmh) => _useMph ? kmh / 1.609344 : kmh;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final SharedPreferences p = _prefs!;
    _overlayEnabled = p.getBool(AppConstants.prefOverlayEnabled) ?? false;
    _voiceEnabled = p.getBool(AppConstants.prefVoiceEnabled) ?? true;
    _beepEnabled = p.getBool(AppConstants.prefBeepEnabled) ?? true;
    // The silence window is restored only while it is still open: a driver who
    // muted the warnings, then killed the app or rebooted the phone, gets them
    // back rather than driving the next trip in silence he has forgotten about.
    final bool paused = p.getBool(AppConstants.prefWarningsPaused) ?? false;
    final int? pausedAt = p.getInt(AppConstants.prefWarningsPausedAt);
    _silence = paused && pausedAt != null
        ? WarningSilence.startingAt(
            DateTime.fromMillisecondsSinceEpoch(pausedAt),
          ).normalised(DateTime.now())
        : WarningSilence.off;
    _language = p.getString(AppConstants.prefLanguage) ?? 'az-AZ';
    _angularTolerance = p.getDouble(AppConstants.prefAngularTolerance) ??
        AppConstants.angularToleranceDegrees;
    _useMph = p.getBool(AppConstants.prefUnitsMph) ?? false;
    _showRemaining = p.getBool(AppConstants.prefShowRemaining) ?? true;
    _overlayScale = p.getDouble(AppConstants.prefOverlayScale) ?? 1.0;
    _syncRadius =
        p.getDouble(AppConstants.prefSyncRadius) ?? AppConstants.defaultSyncRadiusMeters;
    _firebaseUrl = p.getString(AppConstants.prefFirebaseUrl) ?? '';
    final int? lastSync = p.getInt(AppConstants.prefLastSync);
    _lastSync = lastSync == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastSync);
    _onboarded = p.getBool(AppConstants.prefOnboarded) ?? false;
    _logExpanded = p.getBool(AppConstants.prefLogExpanded) ?? false;
    _updateRepo = p.getString(AppConstants.prefUpdateRepo) ?? '';
    _autoUpdateCheck =
        p.getBool(AppConstants.prefAutoUpdateCheck) ?? true;
    final int? updateCheck = p.getInt(AppConstants.prefLastUpdateCheck);
    _lastUpdateCheck = updateCheck == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(updateCheck);
    _loaded = true;
    notifyListeners();
  }

  Future<void> _write<T>(Future<bool> Function() op) async {
    await op();
    notifyListeners();
  }

  Future<void> setOverlayEnabled(bool v) async {
    _overlayEnabled = v;
    await _write(() => _prefs!.setBool(AppConstants.prefOverlayEnabled, v));
  }

  Future<void> setVoiceEnabled(bool v) async {
    _voiceEnabled = v;
    await _write(() => _prefs!.setBool(AppConstants.prefVoiceEnabled, v));
  }

  Future<void> setBeepEnabled(bool v) async {
    _beepEnabled = v;
    await _write(() => _prefs!.setBool(AppConstants.prefBeepEnabled, v));
  }

  /// Opens or closes the silence window.
  ///
  /// Persisted on purpose: the panels that render it (the lock-screen media
  /// card, the bubble) must survive a process death showing what the driver last
  /// asked for, and [WarningSilence.normalised] is what stops a stale window from
  /// outliving its own five minutes.
  Future<void> setWarningSilence(WarningSilence value) async {
    _silence = value;
    final SharedPreferences? p = _prefs;
    if (p != null) {
      await p.setBool(AppConstants.prefWarningsPaused, value.isActive);
      final DateTime? at = value.pausedAt;
      if (at == null) {
        await p.remove(AppConstants.prefWarningsPausedAt);
      } else {
        await p.setInt(AppConstants.prefWarningsPausedAt, at.millisecondsSinceEpoch);
      }
    }
    notifyListeners();
  }

  Future<void> setLanguage(String v) async {
    _language = v;
    await _write(() => _prefs!.setString(AppConstants.prefLanguage, v));
  }

  Future<void> setAngularTolerance(double v) async {
    _angularTolerance = v.clamp(10.0, 90.0);
    await _write(
        () => _prefs!.setDouble(AppConstants.prefAngularTolerance, _angularTolerance));
  }

  Future<void> setUseMph(bool v) async {
    _useMph = v;
    await _write(() => _prefs!.setBool(AppConstants.prefUnitsMph, v));
  }

  Future<void> setShowRemaining(bool v) async {
    _showRemaining = v;
    await _write(() => _prefs!.setBool(AppConstants.prefShowRemaining, v));
  }

  Future<void> setOverlayScale(double v) async {
    _overlayScale = v.clamp(0.7, 1.6);
    await _write(() => _prefs!.setDouble(AppConstants.prefOverlayScale, _overlayScale));
  }

  Future<void> setSyncRadius(double v) async {
    _syncRadius = v.clamp(2000.0, AppConstants.maxSyncRadiusMeters);
    await _write(() => _prefs!.setDouble(AppConstants.prefSyncRadius, _syncRadius));
  }

  Future<void> setFirebaseUrl(String v) async {
    _firebaseUrl = v.trim();
    await _write(() => _prefs!.setString(AppConstants.prefFirebaseUrl, _firebaseUrl));
  }

  Future<void> markSynced([DateTime? at]) async {
    _lastSync = at ?? DateTime.now();
    final int epoch = _lastSync!.millisecondsSinceEpoch;
    await _write(() => _prefs!.setInt(AppConstants.prefLastSync, epoch));
  }

  Future<void> setOnboarded(bool v) async {
    _onboarded = v;
    await _write(() => _prefs!.setBool(AppConstants.prefOnboarded, v));
  }

  Future<void> setLogExpanded(bool v) async {
    _logExpanded = v;
    await _write(() => _prefs!.setBool(AppConstants.prefLogExpanded, v));
  }

  Future<void> setUpdateRepo(String v) async {
    _updateRepo = v.trim();
    await _write(() => _prefs!.setString(AppConstants.prefUpdateRepo, _updateRepo));
  }

  Future<void> setAutoUpdateCheck(bool v) async {
    _autoUpdateCheck = v;
    await _write(() => _prefs!.setBool(AppConstants.prefAutoUpdateCheck, v));
  }

  Future<void> markUpdateChecked([DateTime? at]) async {
    _lastUpdateCheck = at ?? DateTime.now();
    final int epoch = _lastUpdateCheck!.millisecondsSinceEpoch;
    await _write(() => _prefs!.setInt(AppConstants.prefLastUpdateCheck, epoch));
  }

  Future<void> setOverlayPosition(double x, double y) async {
    await _prefs?.setDouble(AppConstants.prefOverlayX, x);
    await _prefs?.setDouble(AppConstants.prefOverlayY, y);
  }

  (double, double) overlayPosition() {
    final SharedPreferences? p = _prefs;
    if (p == null) return (0.0, 0.0);
    return (
      p.getDouble(AppConstants.prefOverlayX) ?? 0.0,
      p.getDouble(AppConstants.prefOverlayY) ?? 0.0,
    );
  }
}
