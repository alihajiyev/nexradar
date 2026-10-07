@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/design_surfaces.dart';

/// Pixel comparisons for the design system.
///
/// These are captured on the developer's machine and are therefore sensitive to
/// the host's font rasteriser, so they are tagged `golden` and CI runs with
/// `flutter test --exclude-tags golden`. Locally:
///
/// ```bash
/// flutter test test/golden_test.dart                 # verify
/// flutter test --update-goldens test/golden_test.dart # re-capture
/// ```
///
/// The images double as a design review artifact: `test/goldens/*.png` is what
/// the app looks like at 390×844 without installing anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignFonts);

  for (final MapEntry<String, Widget Function()> surface
      in designSurfaces.entries) {
    testWidgets('${surface.key} matches the captured design', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = phoneViewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(designHost(surface.value()));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/${surface.key}.png'),
      );
    });
  }
}
