import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/design_surfaces.dart';

/// Layout safety for the design system.
///
/// Each composition is rendered at a real phone viewport and any `RenderFlex`
/// overflow or failed assertion fails the test. This is deliberately
/// machine-independent — the pixel comparisons live in `golden_test.dart`, which
/// is tagged and skipped by CI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Text metrics decide whether a row wraps or overflows, so the real faces
  // have to be in place before anything is laid out.
  setUpAll(loadDesignFonts);

  for (final MapEntry<String, Widget Function()> surface
      in designSurfaces.entries) {
    testWidgets(
      '${surface.key} lays out at 390×844 without overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = phoneViewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(designHost(surface.value()));

        // Advance far enough for the entry animations to land, without
        // `pumpAndSettle` — the radar sweep and the warning ring loop forever.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        expect(tester.takeException(), isNull);
      },
    );
  }
}
