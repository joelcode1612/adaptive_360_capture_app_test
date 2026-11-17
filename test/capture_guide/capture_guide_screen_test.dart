import 'package:adaptive_360_capture_app/features/capture_guide/presentation/screens/capture_guide_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The capture screen the guide opens is created without any injected
  // services; it shows its dark start screen and does no camera work until
  // its own Start button is pressed, so pumping it inside tests is safe.
  Future<void> openGuide(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CaptureGuideScreen()),
    );
    await tester.pump();
  }

  Future<void> advance(WidgetTester tester, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(find.byKey(const Key('guide_next')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('intro section shows the title, plan sphere and entries', (
    tester,
  ) async {
    await openGuide(tester);
    expect(find.text('Capture your space in 360°'), findsOneWidget);
    expect(find.text('You will take 38 photos, guided by the camera. Follow '
        'one target at a time — the app takes each photo for you.'),
        findsOneWidget);
    expect(find.text('Begin with the phone level'), findsOneWidget);
    expect(find.text('Find the numbered target'), findsOneWidget);
    expect(find.text('Wait for the green ring'), findsOneWidget);
    expect(find.byKey(const Key('guide_next')), findsOneWidget);
    // No back button on the intro: the bottom bar is primary-only.
    expect(find.byKey(const Key('guide_back')), findsNothing);
  });

  testWidgets('plan section lists the verified 38-direction capture plan', (
    tester,
  ) async {
    await openGuide(tester);
    await advance(tester);
    expect(find.text('Cover the room from every angle'), findsOneWidget);
    expect(find.text('38 DIRECTIONS'), findsOneWidget);
    expect(find.text('Middle ring · 0°'), findsOneWidget);
    expect(find.text('Upper ring · +35°'), findsOneWidget);
    expect(find.text('Lower ring · −35°'), findsOneWidget);
    expect(find.text('12 targets'), findsNWidgets(3));
    expect(find.text('Zenith · +90°'), findsOneWidget);
    expect(find.text('Nadir · −90°'), findsOneWidget);
  });

  testWidgets('camera section teaches the two circles with the real target '
      'label', (tester) async {
    await openGuide(tester);
    await advance(tester, times: 2);
    expect(find.text('Know which circle to follow'), findsOneWidget);
    // The mock bottom line uses the real SphereTargetSpec.progressLabel.
    expect(find.text('Target 2 / 38 — Middle Ring (30°)'), findsOneWidget);
    expect(find.text('Turn right to align Target 2'), findsOneWidget);
  });

  testWidgets('progress section labels its map as an example, not live '
      'progress', (tester) async {
    await openGuide(tester);
    await advance(tester, times: 3);
    expect(find.text('See which directions are saved'), findsOneWidget);
    expect(
      find.text('38 planned directions · Example map (not live progress)'),
      findsOneWidget,
    );
  });

  testWidgets('tutorial section supports six modes and the 12-direction '
      'selector, preserving selection across sections', (tester) async {
    await openGuide(tester);
    await advance(tester, times: 4);
    expect(find.text('Follow the target into the center circle'),
        findsOneWidget);
    expect(find.text('Start Capture'), findsOneWidget);
    for (final label in [
      'Start position',
      'Middle ring',
      'Upper ring',
      'Lower ring',
      'Ceiling',
      'Floor',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    // Select the upper ring: prompt updates and the direction row appears.
    await tester.tap(find.byKey(const Key('guide_mode_upper')));
    await tester.pump();
    expect(find.text('Aim slightly upward toward the upper targets'),
        findsOneWidget);
    expect(find.byKey(const Key('guide_direction_label')), findsOneWidget);

    // Walk one direction: Forward · 0° → 30° right · 30°. The selector sits
    // below the fold of the 800×600 test viewport, so bring it into view
    // first — the same scroll a real user performs.
    await tester.ensureVisible(find.byKey(const Key('guide_dir_next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('guide_dir_next')));
    await tester.pump();
    expect(find.text('30° right · 30°'), findsOneWidget);

    // Leave to the camera section and come back: mode and direction persist.
    await tester.tap(find.byKey(const Key('guide_back')));
    await tester.pumpAndSettle();
    await advance(tester);
    expect(find.text('Aim slightly upward toward the upper targets'),
        findsOneWidget);
    expect(find.text('30° right · 30°'), findsOneWidget);
  });

  testWidgets('final Start Capture opens the existing capture screen in '
      'place of the guide', (tester) async {
    await openGuide(tester);
    await advance(tester, times: 4);
    await tester.tap(find.byKey(const Key('guide_next')));
    await tester.pumpAndSettle();
    // The replacement route is the real capture screen's start state.
    expect(find.text('AR 360° Capture (38 Targets)'), findsOneWidget);
    expect(find.byType(CaptureGuideScreen), findsNothing);
  });

  testWidgets('in-session help variant returns to capture instead of '
      'starting a new session', (tester) async {
    // Production pushes the guide over the live capture screen, so the
    // harness does the same: 'Return to capture' must pop the pushed route,
    // not replace the app's home.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const CaptureGuideScreen(showStartAction: false),
                  ),
                ),
                child: const Text('open help'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open help'));
    await tester.pumpAndSettle();
    await advance(tester, times: 4);
    expect(find.text('Return to capture'), findsOneWidget);
    expect(find.text('Start Capture'), findsNothing);
    await tester.tap(find.byKey(const Key('guide_next')));
    await tester.pumpAndSettle();
    // The guide popped; the capture screen the harness started from is back.
    expect(find.byType(CaptureGuideScreen), findsNothing);
    expect(find.text('AR 360° Capture (38 Targets)'), findsNothing);
  });

  testWidgets('non-ring modes hide the direction selector with an honest '
      'note', (tester) async {
    await openGuide(tester);
    await advance(tester, times: 4);
    await tester.tap(find.byKey(const Key('guide_mode_zenith')));
    await tester.pump();
    expect(find.byKey(const Key('guide_direction_label')), findsNothing);
    expect(find.text('The pole target has no fixed station anchor.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('guide_mode_start')));
    await tester.pump();
    expect(
      find.text('The first heading is set automatically — no fixed station '
          'anchor.'),
      findsOneWidget,
    );
  });
}
