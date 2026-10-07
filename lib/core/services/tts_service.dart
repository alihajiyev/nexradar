import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../constants/app_constants.dart';

/// Voice announcements in Azerbaijani (default), Turkish, Russian or English.
///
/// Two practical problems are handled here:
///
/// * **Missing voices.** Many Android builds ship without an `az-AZ` voice
///   pack. We probe with [FlutterTts.isLanguageAvailable] and fall back down a
///   chain (`az-AZ → tr-TR → ru-RU → en-US`) so the driver always hears
///   *something* useful instead of silence.
/// * **Spam.** A radar is passed at speed, so every crossing is announced once
///   (the engine only calls us on a crossing), and a short global cooldown
///   protects against chattering when several cameras are close together.
class TtsService {
  TtsService({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  bool _initialised = false;
  bool _speaking = false;

  String _requestedLanguage = 'az-AZ';
  String _effectiveLanguage = 'en-US';

  DateTime _lastSpokeAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get effectiveLanguage => _effectiveLanguage;
  bool get isSpeaking => _speaking;

  Future<void> init({String language = 'az-AZ'}) async {
    if (_initialised) {
      await setLanguage(language);
      return;
    }
    try {
      await _tts.setVolume(1.0);
      await _tts.setPitch(0.95);
      // Slightly slower than default: road announcements must survive engine
      // and wind noise.
      await _tts.setSpeechRate(0.48);
      await _tts.awaitSpeakCompletion(false);
      await _tts.setSharedInstance(true);
      // Signature: (category, options, [mode]) — iOS builds get the voice
      // prompt mode so announcements duck music instead of stopping it.
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        <IosTextToSpeechAudioCategoryOptions>[
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
      _tts.setStartHandler(() => _speaking = true);
      _tts.setCompletionHandler(() => _speaking = false);
      _tts.setCancelHandler(() => _speaking = false);
      _tts.setErrorHandler((dynamic msg) {
        _speaking = false;
        if (kDebugMode) debugPrint('[TTS] error: $msg');
      });
      _initialised = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[TTS] init failed: $e');
    }
    await setLanguage(language);
  }

  /// Resolves a usable voice, walking the fallback chain.
  Future<void> setLanguage(String language) async {
    _requestedLanguage = language;
    for (final String candidate in _fallbackChain(language)) {
      try {
        final dynamic available = await _tts.isLanguageAvailable(candidate);
        if (available == true || available == 'true') {
          await _tts.setLanguage(candidate);
          _effectiveLanguage = candidate;
          if (kDebugMode) {
            debugPrint('[TTS] voice = $candidate (requested $language)');
          }
          return;
        }
      } catch (_) {
        // try the next candidate
      }
    }
    if (kDebugMode) {
      debugPrint('[TTS] no voice from chain for $language');
    }
  }

  List<String> _fallbackChain(String language) {
    final List<String> chain = <String>[language];
    void add(String l) {
      if (!chain.contains(l)) chain.add(l);
    }

    if (language.startsWith('az')) {
      // Azerbaijani speakers overwhelmingly understand Turkish.
      add('az-AZ');
      add('tr-TR');
      add('ru-RU');
    } else if (language.startsWith('tr')) {
      add('tr-TR');
      add('az-AZ');
      add('ru-RU');
    } else if (language.startsWith('ru')) {
      add('ru-RU');
      add('tr-TR');
    }
    add('en-US');
    return chain;
  }

  /// Raw speak with the global cooldown applied.
  Future<void> speak(String sentence, {bool force = false}) async {
    if (sentence.trim().isEmpty) return;
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastSpokeAt) < AppConstants.voiceGlobalCooldown) {
      return;
    }
    _lastSpokeAt = now;
    try {
      await _tts.stop();
      await _tts.speak(sentence);
    } catch (e) {
      if (kDebugMode) debugPrint('[TTS] speak failed: $e');
    }
  }

  /// "İrəlidə radar var, sürət həddi 80!" — fired ~400 m out.
  Future<void> announceCameraAhead({required int limitKmh, int? distanceMeters}) {
    return speak(
      PhraseBook.cameraAhead(
        _requestedLanguage,
        limitKmh: limitKmh,
        distanceMeters: distanceMeters,
      ),
      force: true,
    );
  }

  /// "Yavaşlayın, radara 200 metr qaldı!" — fired ~150 m out.
  Future<void> announceSlowDown({required int distanceMeters, int? limitKmh}) {
    return speak(
      PhraseBook.slowDown(
        _requestedLanguage,
        distanceMeters: distanceMeters,
        limitKmh: limitKmh,
      ),
      force: true,
    );
  }

  /// Fired when the driver is over the posted limit and closing in.
  Future<void> announceSpeeding({required int speedKmh, required int limitKmh}) {
    return speak(
      PhraseBook.speeding(
        _requestedLanguage,
        speedKmh: speedKmh,
        limitKmh: limitKmh,
      ),
      force: true,
    );
  }

  /// Fired inside an average-speed section, where the instant speed is beside
  /// the point: the camera divides distance by time, so the average is the number
  /// that decides whether the driver is fined.
  Future<void> announceSectionAverage({
    required int averageKmh,
    required int limitKmh,
  }) {
    return speak(
      PhraseBook.sectionAverage(
        _requestedLanguage,
        averageKmh: averageKmh,
        limitKmh: limitKmh,
      ),
      force: true,
    );
  }

  Future<void> announceCommunityReport({required int limitKmh}) {
    return speak(
      PhraseBook.communityReport(_requestedLanguage, limitKmh: limitKmh),
      force: true,
    );
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _speaking = false;
  }

  Future<void> dispose() async {
    await stop();
  }
}

/// Localized sentences. Kept out of the service so translators can extend it
/// without touching the engine.
class PhraseBook {
  PhraseBook._();

  /// Short language code helper: `az-AZ` → `az`.
  static String _lang(String language) =>
      language.split('-').first.toLowerCase();

  static String cameraAhead(
    String language, {
    required int limitKmh,
    int? distanceMeters,
  }) {
    final int d = _roundDistance(distanceMeters ?? 400);
    switch (_lang(language)) {
      case 'az':
        return 'İrəlidə radar var, sürət həddi $limitKmh kilometr saat, '
            '$d metr qaldı.';
      case 'tr':
        return 'İleride radar var, hız limiti $limitKmh, $d metre kaldı.';
      case 'ru':
        return 'Впереди камера, ограничение $limitKmh километров в час, '
            'осталось $d метров.';
      default:
        return 'Speed camera ahead, the limit is $limitKmh, '
            'in $d meters.';
    }
  }

  static String slowDown(
    String language, {
    required int distanceMeters,
    int? limitKmh,
  }) {
    final int d = _roundDistance(distanceMeters);
    switch (_lang(language)) {
      case 'az':
        return 'Yavaşlayın, radara $d metr qaldı!';
      case 'tr':
        return 'Yavaşlayın, radara $d metre kaldı!';
      case 'ru':
        return 'Снизьте скорость, до камеры $d метров!';
      default:
        return 'Slow down, camera in $d meters!';
    }
  }

  static String sectionAverage(
    String language, {
    required int averageKmh,
    required int limitKmh,
  }) {
    switch (_lang(language)) {
      case 'az':
        return 'Orta sürət bölməsi! Ortalamanız $averageKmh, hədd $limitKmh.';
      case 'tr':
        return 'Ortalama hız bölümü! Ortalamanız $averageKmh, limit $limitKmh.';
      case 'ru':
        return 'Зона средней скорости! Ваша средняя $averageKmh при $limitKmh.';
      default:
        return 'Average speed zone! Your average is $averageKmh, '
            'the limit is $limitKmh.';
    }
  }

  static String speeding(
    String language, {
    required int speedKmh,
    required int limitKmh,
  }) {
    switch (_lang(language)) {
      case 'az':
        return 'Sürəti azaldın! $speedKmh, hədd $limitKmh!';
      case 'tr':
        return 'Hızınızı düşürün! $speedKmh, limit $limitKmh!';
      case 'ru':
        return 'Превышение! $speedKmh при ограничении $limitKmh!';
      default:
        return 'Slow down! $speedKmh in a $limitKmh zone!';
    }
  }

  static String communityReport(String language, {required int limitKmh}) {
    switch (_lang(language)) {
      case 'az':
        return 'Diqqət, sürücülərin bildirdiyi radar. Hədd $limitKmh.';
      case 'tr':
        return 'Dikkat, sürücü bildirimi radar. Limit $limitKmh.';
      case 'ru':
        return 'Внимание, камера по сообщению водителей. Ограничение $limitKmh.';
      default:
        return 'Heads up, a driver-reported camera. Limit $limitKmh.';
    }
  }

  static int _roundDistance(int meters) {
    if (meters >= 1000) return (meters / 100).round() * 100;
    if (meters >= 200) return (meters / 50).round() * 50;
    return (meters / 10).round() * 10;
  }
}
