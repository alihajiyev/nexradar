import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/app_constants.dart';

/// The audible/kinetic half of the alert ladder: short beeps played from local
/// WAV assets plus haptic feedback.
///
/// [PlayerMode.lowLatency] matters here — the default media pipeline can add
/// 100-200 ms of latency, which at 110 km/h is several meters of travel. The
/// players are pre-loaded once and simply `resume()`d, so playback is
/// essentially immediate.
class AlertService {
  AlertService();

  final AudioPlayer _tickPlayer = AudioPlayer(playerId: 'nex_radar_tick');
  final AudioPlayer _alarmPlayer = AudioPlayer(playerId: 'nex_radar_alarm');

  bool _ready = false;
  DateTime _lastTickAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAlarmAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isReady => _ready;

  Future<void> init() async {
    try {
      await _prepare(_tickPlayer, 'audio/beep_tick.wav', volume: 0.55);
      await _prepare(_alarmPlayer, 'audio/beep_alarm.wav', volume: 0.95);
      _ready = true;
    } catch (e) {
      _ready = false;
      if (kDebugMode) debugPrint('[AlertService] init failed: $e');
    }
  }

  Future<void> _prepare(
    AudioPlayer player,
    String asset, {
    required double volume,
  }) async {
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setPlayerMode(PlayerMode.lowLatency);
    await player.setVolume(volume);
    await player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const <AVAudioSessionOptions>{
            AVAudioSessionOptions.mixWithOthers,
          },
        ),
      ),
    );
    await player.setSource(AssetSource(asset));
  }

  /// Soft tick played while approaching a camera (max once per 900 ms).
  Future<void> tick() async {
    final DateTime now = DateTime.now();
    if (now.difference(_lastTickAt) < AppConstants.beepCooldown) return;
    _lastTickAt = now;
    await HapticFeedback.selectionClick();
    await _play(_tickPlayer);
  }

  /// Urgent double beep — speeding inside the warning zone.
  Future<void> alarm() async {
    final DateTime now = DateTime.now();
    if (now.difference(_lastAlarmAt) < AppConstants.alarmRepeatInterval) return;
    _lastAlarmAt = now;
    await HapticFeedback.heavyImpact();
    await _play(_alarmPlayer);
  }

  Future<void> _play(AudioPlayer player) async {
    if (!_ready) return;
    try {
      await player.stop();
      await player.resume();
    } catch (e) {
      if (kDebugMode) debugPrint('[AlertService] play failed: $e');
    }
  }

  Future<void> stopAll() async {
    try {
      await _tickPlayer.stop();
      await _alarmPlayer.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _tickPlayer.dispose();
    await _alarmPlayer.dispose();
  }
}
