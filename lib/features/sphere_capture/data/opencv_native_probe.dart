/// Runtime verification that the bundled OpenCV native library actually
/// exports what the panorama pipeline calls.
///
/// ## Why this exists
///
/// `dartcv4` links through Dart *native assets*, so a module that was compiled
/// out is not a build error — the Dart code still compiles, the APK still
/// installs, and the failure appears only at the moment a binding is called:
///
/// ```text
/// Couldn't resolve native function 'cv_cvtColor'
/// in 'package:dartcv4/dartcv.dart'.
/// Failed to lookup symbol 'cv_cvtColor': undefined symbol: cv_cvtColor
/// ```
///
/// That message names the symbol but not the cause. The cause is a module list:
/// `dartcv4`'s build hook **replaces** its default module set with
/// `hooks.user_defines.dartcv4.include_modules` (`modules..clear()..addAll(...)`),
/// so omitting `imgproc` removes `cvtColor`, `laplacian` and `resize` from the
/// shipped `libdartcv.so` while leaving `imread`, `Stitcher` and `ORB` intact.
///
/// This probe calls one representative binding per module, catches the failure,
/// and reports **which module** is missing so the message is actionable. It runs
/// against the installed native library — the same handles the pipeline uses —
/// not against the Dart source.
///
/// ## It does not crash the app
///
/// Every check is isolated. A missing symbol is reported as a capability gap;
/// the stitcher turns that into a normal `StitchResult.failure` with the captured
/// frames untouched, so the user can fix the build and retry without recapturing.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// The result of one native call.
class OpenCvCapability {
  const OpenCvCapability({
    required this.module,
    required this.feature,
    required this.ok,
    this.detail,
  });

  /// The OpenCV module that must be listed in
  /// `hooks.user_defines.dartcv4.include_modules`.
  final String module;

  /// The binding that was called, e.g. `cvtColor`.
  final String feature;

  /// Whether the symbol resolved and the call completed (or failed for a reason
  /// that is not a missing symbol — see [OpenCvNativeProbe.run]).
  final bool ok;

  /// Why it failed, or a short note when the call was exercised indirectly.
  final String? detail;

  @override
  String toString() =>
      '$module/$feature ${ok ? 'ok' : 'MISSING'}${detail == null ? '' : ' ($detail)'}';
}

/// Runs the checks. Cheap enough to call before every panorama generation.
abstract final class OpenCvNativeProbe {
  /// Modules the panorama pipeline cannot work without.
  ///
  /// `features2d` (ORB/BFMatcher) and `calib3d` (findHomography) are required by
  /// the frame registration that precedes the projection; `stitching` is the
  /// panorama engine; `imgcodecs` decodes the JPEGs; `imgproc` converts colour
  /// and resizes. `flann` is a dependency of the feature matchers and has no
  /// call of its own to probe.
  static const List<String> requiredModules = <String>[
    'imgproc',
    'imgcodecs',
    'features2d',
    'calib3d',
    'stitching',
  ];

  /// Calls one binding per module and returns what happened.
  ///
  /// A call that throws for a reason **other** than symbol resolution counts as
  /// [OpenCvCapability.ok]: the symbol was found, which is what is being
  /// verified here. Only "couldn't resolve native function" / "undefined
  /// symbol" is a capability gap.
  static List<OpenCvCapability> run() {
    final capabilities = <OpenCvCapability>[];

    // ── imgproc ──────────────────────────────────────────────────────────
    capabilities.add(_check('imgproc', 'cvtColor', () {
      final src = cv.Mat.zeros(8, 8, cv.MatType.CV_8UC3);
      try {
        final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
        try {
          if (gray.rows != 8 || gray.cols != 8 || gray.channels != 1) {
            throw StateError(
              'cvtColor returned ${gray.cols}x${gray.rows} with '
              '${gray.channels} channel(s)',
            );
          }
        } finally {
          gray.dispose();
        }
      } finally {
        src.dispose();
      }
    }));

    // ── imgcodecs ────────────────────────────────────────────────────────
    // Encode *and* decode: the stitcher does both, and the two live in the same
    // module but are separate entry points.
    capabilities.add(_check('imgcodecs', 'imencode+imdecode', () {
      final src = cv.Mat.zeros(8, 8, cv.MatType.CV_8UC3);
      try {
        final (ok, bytes) = cv.imencode('.png', src);
        if (!ok || bytes.isEmpty) {
          throw StateError('imencode produced no bytes');
        }
        final decoded = cv.imdecode(bytes, cv.IMREAD_COLOR);
        try {
          if (decoded.isEmpty) {
            throw StateError('imdecode produced an empty Mat');
          }
        } finally {
          decoded.dispose();
        }
      } finally {
        src.dispose();
      }
    }));

    // ── features2d ───────────────────────────────────────────────────────
    capabilities.add(_check('features2d', 'ORB.create+detect', () {
      final orb = cv.ORB.create(nFeatures: 50);
      final src = cv.Mat.zeros(32, 32, cv.MatType.CV_8UC1);
      try {
        // Zeros yield no corners; the point is that the call returns rather
        // than failing to resolve cv_ORB_create / cv_ORB_detect.
        orb.detect(src);
      } finally {
        src.dispose();
        orb.dispose();
      }
    }));

    // ── calib3d ──────────────────────────────────────────────────────────
    capabilities.add(_check('calib3d', 'findHomography', () {
      final src = cv.VecPoint2f.fromList(<cv.Point2f>[
        cv.Point2f(0, 0),
        cv.Point2f(1, 0),
        cv.Point2f(1, 1),
        cv.Point2f(0, 1),
      ]);
      final dst = cv.VecPoint2f.fromList(<cv.Point2f>[
        cv.Point2f(2, 2),
        cv.Point2f(4, 2),
        cv.Point2f(4, 4),
        cv.Point2f(2, 4),
      ]);
      final h = cv.findHomography(cv.Mat.fromVec(src), cv.Mat.fromVec(dst));
      h.dispose();
    }));

    // ── stitching ────────────────────────────────────────────────────────
    capabilities.add(_check('stitching', 'Stitcher.create', () {
      final stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA);
      stitcher.dispose();
    }));

    return capabilities;
  }

  /// The modules that are compiled out, in [requiredModules] order.
  static List<String> missingModules(List<OpenCvCapability> capabilities) {
    final missing = <String>{};
    for (final capability in capabilities) {
      if (!capability.ok) missing.add(capability.module);
    }
    return requiredModules.where(missing.contains).toList(growable: false);
  }

  /// A user-facing sentence naming the missing modules, or `null` when the
  /// native library is complete.
  ///
  /// It names the module and the build setting rather than the symbol: the
  /// symbol is a symptom, and telling a user "cv_cvtColor is undefined" invites
  /// a search for a Dart bug that does not exist.
  static String? failureMessage(List<OpenCvCapability> capabilities) {
    final missing = missingModules(capabilities);
    if (missing.isEmpty) return null;
    final details = capabilities
        .where((OpenCvCapability c) => !c.ok)
        .map((OpenCvCapability c) => '${c.module}/${c.feature}')
        .join(', ');
    return 'This build of the app is missing native OpenCV support for '
        '${missing.join(', ')} ($details). The 38 photographs are safe — '
        'rebuild with those modules enabled in '
        'hooks.user_defines.dartcv4.include_modules, then retry stitching.';
  }

  /// Logs one line per capability. Used by the debug startup diagnostic and by
  /// the stitcher before it spawns the projection isolate.
  static void log(List<OpenCvCapability> capabilities, {String tag = 'SPHERE_NATIVE'}) {
    for (final capability in capabilities) {
      debugPrint('$tag: $capability');
    }
  }

  static OpenCvCapability _check(
    String module,
    String feature,
    void Function() body,
  ) {
    try {
      body();
      return OpenCvCapability(module: module, feature: feature, ok: true);
    } catch (error) {
      if (_isMissingSymbol(error)) {
        return OpenCvCapability(
          module: module,
          feature: feature,
          ok: false,
          detail: _short(error),
        );
      }
      // The symbol resolved; the call itself objected to something (an empty
      // input, an unsupported combination). That is not a capability gap.
      return OpenCvCapability(
        module: module,
        feature: feature,
        ok: true,
        detail: 'resolved; call reported: ${_short(error)}',
      );
    }
  }

  /// Whether [error] is Dart failing to bind a native symbol, rather than an
  /// OpenCV error returned by a symbol that *did* resolve.
  static bool _isMissingSymbol(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('resolve native function') ||
        text.contains('failed to lookup symbol') ||
        text.contains('undefined symbol') ||
        text.contains('is not available in the process');
  }

  static String _short(Object error) {
    final text = error.toString().replaceAll('\n', ' ');
    return text.length <= 160 ? text : '${text.substring(0, 157)}…';
  }
}
