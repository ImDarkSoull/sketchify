import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify_example/main.dart';

void main() {
  for (final size in const [Size(360, 780), Size(1440, 900)]) {
    testWidgets('lays out without overflow at ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const SketchifyShowcase());
      // Let the first sample trace (real async work), then draw it in.
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(Slider), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Neon'));
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);

      // Switch images: new ones trace (real async work), cached ones swap in
      // mid-animation. Each switch restarts the drawing.
      for (final name in ['Rocket', 'Owl', 'Cat', 'Rocket', 'Sunset', 'Coffee', 'Lettering', 'Cat']) {
        await tester.ensureVisible(find.text(name));
        await tester.tap(find.text(name));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull, reason: 'switching to $name');
      }
      expect(find.text('Tracing…'), findsNothing);
      // Rocket was traced earlier in this session, so it comes from the cache.
      await tester.ensureVisible(find.text('Rocket'));
      await tester.tap(find.text('Rocket'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      // On a phone the stage is at the top of the scrolling list.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('from cache'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);
    });
  }
}
