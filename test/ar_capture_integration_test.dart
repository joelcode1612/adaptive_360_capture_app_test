import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';

/// The parts of the source project's `ar_capture_integration_test.dart` that
/// belong to a standalone capture app: the 26-target sphere identity and the
/// ARCore channel contract.
///
/// The source file's `SiteWiseCaptureRepository` and `tourForPropertyDraft`
/// groups are deliberately not ported — they test the SiteWise tour manifest
/// and draft database, which §5 excludes. The standalone persistence contract
/// lives in `capture_persistence_test.dart` against `FileCaptureRepository`.
void main() {
  group('26-target sphere geometry', () {
    test('builds exactly 26 unique, ordered directions', () {
      final specs = buildCaptureSphere();
      expect(specs.length, 26);
      expect(
        specs.map((s) => s.targetId).toList(),
        List<int>.generate(26, (i) => i + 1),
      );
      expect(specs.map((s) => s.targetId).toSet().length, 26);
    });

    test('keeps the two poles and the three rings', () {
      final specs = buildCaptureSphere();
      final zenith = specs.firstWhere((s) => s.isZenith);
      final nadir = specs.firstWhere((s) => s.isNadir);
      expect(zenith.pitchDegrees, 90);
      expect(nadir.pitchDegrees, -90);
      expect(specs.where((s) => s.ringName == 'Horizontal').length, 8);
      expect(specs.where((s) => s.ringName == 'Upper').length, 8);
      expect(specs.where((s) => s.ringName == 'Lower').length, 8);
    });

    test('every direction is a unit vector', () {
      for (final spec in buildCaptureSphere()) {
        expect(spec.direction.length, closeTo(1, 1e-9));
      }
    });
  });

  group('ARCore channel contract', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const channel = MethodChannel('test/arcore');
    const events = EventChannel('test/arcore/events');
    late List<MethodCall> calls;

    ArCoreHost host() => ArCoreHost(channel: channel, events: events);

    void answer(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) {
            calls.add(call);
            return handler(call);
          });
    }

    setUp(() => calls = <MethodCall>[]);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'probeDirections reads the host outcome map, not a bare list',
      () async {
        // The Kotlin host wraps every answer in an outcome map: the probe list
        // arrives under `results`. Reading it as a bare list threw a cast error
        // on every scan, which is what made all 26 targets report "no surface".
        answer((MethodCall call) async {
          expect(call.method, 'probeDirections');
          final args = call.arguments as Map;
          expect((args['directions'] as List).length, 6);
          return <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'hit': true,
                'distanceM': 2.5,
                'planeType': 'VERTICAL',
              },
              <String, Object?>{'hit': false},
            ],
          };
        });

        final probes = await host().probeDirections(
          origin: const Vec3(0, 0, 0),
          directions: const <Vec3>[Vec3(0, 0, 1), Vec3(1, 0, 0)],
        );

        expect(probes.length, 2);
        expect(probes[0].found, isTrue);
        expect(probes[0].distanceM, 2.5);
        expect(probes[0].surfaceType, 'VERTICAL');
        expect(probes[1].found, isFalse);
      },
    );

    test('probeDirections still accepts a bare list from the host', () async {
      answer((MethodCall call) async {
        return <Object?>[
          <String, Object?>{'hit': true, 'distanceM': 1.25},
        ];
      });

      final probes = await host().probeDirections(
        origin: const Vec3(0, 0, 0),
        directions: const <Vec3>[Vec3(0, 0, 1)],
      );

      expect(probes.single.found, isTrue);
      expect(probes.single.distanceM, 1.25);
    });

    test('an empty outcome map is a miss, not a fabricated hit', () async {
      answer((MethodCall call) async => <String, Object?>{});

      final probes = await host().probeDirections(
        origin: const Vec3(0, 0, 0),
        directions: const <Vec3>[Vec3(0, 0, 1)],
      );

      expect(probes, isEmpty);
    });

    test('shared host default keeps plane detection enabled', () async {
      answer((MethodCall call) async {
        expect(call.method, 'start');
        final args = call.arguments as Map;
        expect(args['planes'], isTrue);
        return <String, Object?>{
          'textureId': 7,
          'planes': true,
          'anchors': true,
          'cameraImage': true,
        };
      });

      final session = await host().start(width: 1080, height: 1920);
      expect(session.textureId, 7);
      expect(session.planes, isTrue);
      expect(session.cameraImage, isTrue);
      expect(session.reused, isFalse);
    });

    test('host can explicitly start markerless with planes disabled', () async {
      answer((MethodCall call) async {
        expect(call.method, 'start');
        final args = call.arguments as Map;
        expect(args['planes'], isFalse);
        return <String, Object?>{
          'textureId': 8,
          'planes': false,
          'anchors': true,
          'cameraImage': true,
        };
      });

      final session = await host().start(
        width: 1080,
        height: 1920,
        planes: false,
      );
      expect(session.planes, isFalse);
      expect(session.anchors, isTrue);
      expect(session.canAnchor, isFalse);
      expect(session.canShoot, isTrue);
    });
  });
}
