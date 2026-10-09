import 'package:flutter_test/flutter_test.dart';
import 'package:nex_radar/core/services/overlay_service.dart';

/// The bubble and the radar pipeline have to agree, and they are recorded in two
/// different places: the app's preference and the native service's own flag. This
/// file pins down the only rule that reconciles them.
///
/// The failure it exists to prevent is the one a driver hits on the *lock
/// screen*: a bubble that is on screen (so the keyguard shows it, and the media
/// panel publishes it) while nothing is computing behind it. That state looks
/// exactly like a working app reading 0, which is why the app must never start
/// up believing the two stores disagree when they do not, and must never leave a
/// visible bubble unarmed when they do.
void main() {
  group('decideBackgroundResume', () {
    test('nothing wanted on either side → the bootstrap leaves everything alone',
        () {
      expect(
        decideBackgroundResume(prefEnabled: false, nativeDesired: false),
        BackgroundResume.none,
      );
    });

    test('a visible bubble the preference never heard about is adopted', () {
      // What a stop from the lock screen, an update or a process death leaves
      // behind: the native flag survives, the Dart one does not. The driver can
      // see the bubble, so his eyes win over the stored preference.
      expect(
        decideBackgroundResume(prefEnabled: false, nativeDesired: true),
        BackgroundResume.adopt,
      );
    });

    test('a recorded wish arms the pipeline, window or no window', () {
      // The driver asked for the radar and the native flag was lost (fresh
      // data, a cleared copy): bring the window back too.
      expect(
        decideBackgroundResume(prefEnabled: true, nativeDesired: false),
        BackgroundResume.arm,
      );
      // The common case: both agree, and the pipeline still has to be started —
      // reopening the app must not leave a bubble the driver switched on last
      // week showing a dial that never moves.
      expect(
        decideBackgroundResume(prefEnabled: true, nativeDesired: true),
        BackgroundResume.arm,
      );
    });

    test('only "nobody wants it" is a no-op', () {
      // Guards the tempting shortcut of treating "the stores agree" as nothing
      // to do: agreeing can also mean "both say yes", which still needs the
      // engine started.
      expect(
        decideBackgroundResume(prefEnabled: true, nativeDesired: true),
        isNot(BackgroundResume.none),
      );
    });
  });

  group('OverlayService.isDesired', () {
    test('is inert off Android instead of throwing', () async {
      // The host test VM is not Android, so the method channel has no handler at
      // all. A cold start on such a platform must still boot.
      expect(await OverlayService().isDesired(), isFalse);
    });
  });
}
