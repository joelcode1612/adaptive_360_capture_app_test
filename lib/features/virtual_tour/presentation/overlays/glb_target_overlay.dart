/// The 3D capture target, drawn over the camera preview.
///
/// This is the piece the source repository never closed: it registered
/// `ar_capture_target.glb` and `white_frame_bezel.glb`, wrote
/// `ar_target_model.dart` as a *specification* of them, and left
/// [ArTargetRenderer] an empty seam with a flat 2D marker in its place, on the
/// grounds that drawing a glTF model needs a native Sceneform/filament renderer.
/// It does not — [GlbTargetScene] projects the real geometry in pure Dart, so
/// the arrangement works with no native code, no plugin, and no device, and the
/// numbers behind it are pinned by `test/glb_checks.dart`.
///
/// Two responsibilities live here and nothing else: loading (once, cached) and
/// painting. Placement, colour, check visibility and opacity all come from
/// [GlbTargetScene], which is Flutter-free on purpose.
///
/// Renderer-specific limitations, in the brief's words "document any
/// renderer-specific limitations":
/// * painter's algorithm, no depth buffer — the bezel is recessed by a measured
///   6 mm ([arBezelSetbackM]) to separate its inner wall from the plate's rim,
///   which are coincident cylinders at `r = 0.270`. The two models do **not**
///   overlap in x/y; the ring surrounds the plate and they abut;
/// * no near-plane clipping — triangles touching the near plane are dropped, so
///   a marker pressed against the lens loses its outer ring rather than
///   inverting;
/// * flat shading only — both assets are authored without `NORMAL`;
/// * no textures and no lighting, so a material's `baseColorTexture` would be
///   ignored (neither shipped asset has one);
/// * about 1 000 triangles per frame in pure Dart, which is fine at the capture
///   tick rate but is not a general-purpose 3D pipeline.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_target_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_model.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_renderer.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/glb/glb_target_scene.dart';

/// The two capture models, loaded and parsed exactly once per process.
class GlbCaptureModels {
  final GlbModel target;
  final GlbModel bezel;

  /// Whether the parsed bounds still agree with [ArTargetModel] /
  /// [ArBezelModel]. False means the asset changed under the spec; the overlay
  /// says so instead of drawing a plausible-looking wrong marker.
  final bool matchesSpec;

  const GlbCaptureModels({
    required this.target,
    required this.bezel,
    required this.matchesSpec,
  });

  static final Map<String, Future<GlbModel>> _cache =
      <String, Future<GlbModel>>{};

  /// Loads [targetAssetPath] and [bezelAssetPath] through `rootBundle`.
  ///
  /// Throws [GlbParseException] for a malformed asset and rethrows the bundle's
  /// own error (an unregistered path, a missing file) unchanged — either way the
  /// caller has a message to show, which is the "handle loading failures" half
  /// of the requirement.
  static Future<GlbCaptureModels> load({
    String targetAssetPath = arTargetAssetPath,
    String bezelAssetPath = arBezelAssetPath,
  }) async {
    final target = await _loadOne(targetAssetPath);
    final bezel = await _loadOne(bezelAssetPath);
    return GlbCaptureModels(
      target: target,
      bezel: bezel,
      matchesSpec:
          GlbTargetTopology.targetMatchesSpec(target) &&
          GlbTargetTopology.bezelMatchesSpec(bezel),
    );
  }

  static Future<GlbModel> _loadOne(String path) {
    return _cache.putIfAbsent(path, () async {
      final ByteData data;
      try {
        data = await rootBundle.load(path);
      } catch (e) {
        throw GlbParseException(
          'the asset bundle has no "$path" ($e)',
          source: path,
        );
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return parseGlb(bytes, source: path);
    });
  }

  /// Clears the cache. Only for tests and for a hot asset replacement.
  @visibleForTesting
  static void clearCache() => _cache.clear();

  int get triangleCount => target.triangleCount + bezel.triangleCount;
}

/// The renderer the capture screen drives.
///
/// Implements the [ArTargetRenderer] seam, is a [Listenable] so the overlay
/// repaints when the marker moves, and owns the load state:
///
/// * [status] — `loading` until both assets are parsed, then `ready` or
///   `failed`;
/// * [failureReason] — what to show the user when it is `failed`;
/// * [usesFallback] — whether the flat 2D marker is what the user is seeing.
class GlbTargetRenderer extends ChangeNotifier implements ArTargetRenderer {
  GlbTargetRenderer._({
    this.targetAssetPath = arTargetAssetPath,
    this.bezelAssetPath = arBezelAssetPath,
    this._models,
  });

  /// Creates a renderer and starts loading both assets.
  factory GlbTargetRenderer.load({
    String targetAssetPath = arTargetAssetPath,
    String bezelAssetPath = arBezelAssetPath,
  }) {
    final renderer = GlbTargetRenderer._(
      targetAssetPath: targetAssetPath,
      bezelAssetPath: bezelAssetPath,
    );
    renderer._startLoading();
    return renderer;
  }

  /// A renderer for models that are already in memory (tests, a preview).
  factory GlbTargetRenderer.withModels(GlbCaptureModels models) =>
      GlbTargetRenderer._(models: models).._status = GlbRenderStatus.ready;

  final String targetAssetPath;
  final String bezelAssetPath;

  GlbCaptureModels? _models;
  GlbRenderStatus _status = GlbRenderStatus.loading;
  String? _failureReason;
  GlbTargetScene? _scene;

  ArTargetRenderState _state = const ArTargetRenderState(
    state: ArTargetVisualState.idle,
  );
  bool _visible = true;

  // The last placement, so the 2D fallback and the 3D marker agree about where
  // the target is even when one of them has nothing to draw.
  double _screenX = 0;
  double _screenY = 0;
  double _scale = 1;
  double _rotXDeg = 0;
  double _rotYDeg = 0;
  bool _placed = false;

  int _revision = 0;

  GlbRenderStatus get status => _status;
  String? get failureReason => _failureReason;
  GlbCaptureModels? get models => _models;
  int get revision => _revision;
  bool get isPlaced => _placed;
  double get screenX => _screenX;
  double get screenY => _screenY;

  /// The last state applied, so the flat fallback marker is the same colour and
  /// shows the same checks as the 3D target would.
  ArTargetRenderState get lastState => _state;

  /// True when the models are not available at all, so the flat 2D marker is
  /// standing in for them for every frame. A ready renderer can still have an
  /// empty frame — that is the target genuinely behind the camera, which the
  /// overlay handles per frame rather than here.
  bool get usesFallback => _status != GlbRenderStatus.ready;

  /// The frame's geometry, in draw order. Empty when there is nothing to draw.
  List<GlbScreenTriangle> currentTriangles({
    required Quat cameraPose,
    required Vec3 cameraPosition,
    required double viewportW,
    required double viewportH,
    required double hfovDeg,
    required double vfovDeg,
    double distanceM = arTargetDistanceM,
  }) {
    final scene = _scene;
    if (scene == null || !_visible || !_placed) {
      return const <GlbScreenTriangle>[];
    }
    return scene.triangles(
      camera: GlbCamera(
        pose: cameraPose,
        position: cameraPosition,
        viewportW: viewportW,
        viewportH: viewportH,
        hfovDeg: hfovDeg,
        vfovDeg: vfovDeg,
      ),
      distanceM: distanceM,
    );
  }

  void _startLoading() {
    GlbCaptureModels.load(
          targetAssetPath: targetAssetPath,
          bezelAssetPath: bezelAssetPath,
        )
        .then((models) {
          if (!models.matchesSpec) {
            _status = GlbRenderStatus.failed;
            _failureReason =
                'The capture models on disk no longer match their specification '
                '(expected a 0.54 m plate, a 0.20 m centre and a 0.70 m bezel); '
                '3D guidance is off.';
          } else {
            _models = models;
            _scene = GlbTargetScene(
              targetModel: models.target,
              bezelModel: models.bezel,
            )..apply(_state);
            _scene!.setVisible(_visible);
            if (_placed) _rereplace();
            _status = GlbRenderStatus.ready;
          }
          notifyListeners();
        })
        .catchError((Object e) {
          _status = GlbRenderStatus.failed;
          _failureReason = e is GlbParseException
              ? 'Capture model "${e.source ?? targetAssetPath}" could not be read: '
                    '${e.message}'
              : 'Capture models could not be loaded: $e';
          notifyListeners();
        });
  }

  void _rereplace() {
    _scene?.placeTarget(
      screenX: _screenX,
      screenY: _screenY,
      scale: _scale,
      rotXDeg: _rotXDeg,
      rotYDeg: _rotYDeg,
    );
  }

  // ── ArTargetRenderer ────────────────────────────────────────────────────

  @override
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _scene?.setVisible(visible);
    _revision++;
    notifyListeners();
  }

  @override
  void placeTarget({
    required double screenX,
    required double screenY,
    required double scale,
    required double rotXDeg,
    required double rotYDeg,
  }) {
    setPlacement(
      screenX: screenX,
      screenY: screenY,
      scale: scale,
      rotXDeg: rotXDeg,
      rotYDeg: rotYDeg,
    );
    _revision++;
    notifyListeners();
  }

  /// Records where the marker sits, without announcing it.
  ///
  /// The screen only learns the projected position while it is building, and a
  /// `notifyListeners()` there would rebuild [GlbTargetOverlay] in the middle of
  /// its own frame. The overlay reads this placement on the same pass, so the
  /// 3D marker and the 2D fallback are positioned from one number. The
  /// engine-facing [placeTarget] is this plus the notification.
  void setPlacement({
    required double screenX,
    required double screenY,
    double scale = 1,
    double rotXDeg = 0,
    double rotYDeg = 0,
  }) {
    _screenX = screenX;
    _screenY = screenY;
    _scale = scale;
    _rotXDeg = rotXDeg;
    _rotYDeg = rotYDeg;
    _placed = true;
    _rereplace();
  }

  @override
  void apply(ArTargetRenderState state) {
    _state = state;
    _scene?.apply(state);
    _revision++;
    notifyListeners();
  }
}

/// Load state of [GlbTargetRenderer].
enum GlbRenderStatus { loading, ready, failed }

/// The 3D target over the camera preview, with the 2D marker as its fallback.
///
/// Mount it as the last child of the viewfinder `Stack`, after the feed:
///
/// ```dart
/// final renderer = GlbTargetRenderer.load();          // state of the screen
/// ...
/// GlbTargetOverlay(
///   renderer: renderer,
///   cameraPose: q,                 // the same quaternion the guidance uses
///   hfovDeg: session.params.hfovDeg,
///   vfovDeg: session.params.vfovDeg,
/// )
/// // once per guidance tick, with the pinhole result already in hand:
/// renderer.setPlacement(screenX: p.u, screenY: p.v);
/// // and, from outside the build, whenever the guidance changes:
/// renderer.apply(ArTargetRenderState(state: s, outOfView: outside));
/// ```
///
/// Use [GlbTargetRenderer.setPlacement] rather than
/// [GlbTargetRenderer.placeTarget] when the position is computed during a build;
/// see that method for why.
///
/// The overlay sizes itself to the preview via `LayoutBuilder`, so `screenX` /
/// `screenY` must be in the same logical pixels as `project()` was given. The
/// screen owns the renderer, so it must also `renderer.dispose()` on teardown —
/// the parsed models themselves are cached process-wide and cost nothing to
/// reload.
class GlbTargetOverlay extends StatelessWidget {
  const GlbTargetOverlay({
    super.key,
    required this.renderer,
    required this.cameraPose,
    required this.hfovDeg,
    required this.vfovDeg,
    this.cameraPosition = Vec3.zero,
    this.distanceM = arTargetDistanceM,
    this.showFailureBanner = true,
  });

  final GlbTargetRenderer renderer;

  /// The device pose quaternion, i.e. the same [Quat] handed to `project()`.
  final Quat cameraPose;

  /// The camera's world position. The marker is aim-locked, so with a pose-only
  /// camera this stays at the origin; pass the real AR position when the session
  /// has one, since it changes the billboard's viewing angle.
  final Vec3 cameraPosition;
  final double hfovDeg;
  final double vfovDeg;

  /// How far down the aim ray the marker is planted, in metres. Larger means
  /// smaller on screen; it only matters when [cameraPosition] is not the origin.
  final double distanceM;
  final bool showFailureBanner;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: renderer,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (!w.isFinite || !h.isFinite) {
          return const SizedBox.shrink();
        }
        final placed = renderer.isPlaced;
        final showBanner =
            renderer.status == GlbRenderStatus.failed && showFailureBanner;
        if (!placed && !showBanner) return const SizedBox.shrink();
        final triangles = placed
            ? renderer.currentTriangles(
                cameraPose: cameraPose,
                cameraPosition: cameraPosition,
                viewportW: w,
                viewportH: h,
                hfovDeg: hfovDeg,
                vfovDeg: vfovDeg,
                distanceM: distanceM,
              )
            : const <GlbScreenTriangle>[];
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (triangles.isNotEmpty)
              CustomPaint(
                painter: GlbTargetOverlayPainter(
                  triangles: triangles,
                  revision: renderer.revision,
                ),
              )
            else if (placed)
              // No geometry: the flat marker keeps the guidance usable. Either
              // the models failed to load, or this frame's target is behind the
              // camera and there is nothing 3D to draw at it.
              Positioned(
                left: clampDouble(
                  renderer.screenX - _FlatTargetMarker.size / 2,
                  0.0,
                  w - _FlatTargetMarker.size,
                ),
                top: clampDouble(
                  renderer.screenY - _FlatTargetMarker.size / 2,
                  0.0,
                  h - _FlatTargetMarker.size,
                ),
                child: _FlatTargetMarker(state: renderer.lastState),
              ),
            if (showBanner)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: GlbRenderFailureBanner(
                  reason: renderer.failureReason ?? '',
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// Fills the projected triangles in painter's order.
class GlbTargetOverlayPainter extends CustomPainter {
  final List<GlbScreenTriangle> triangles;

  /// Bumped by the renderer on every state change, so `shouldRepaint` is cheap
  /// and exact.
  final int revision;

  GlbTargetOverlayPainter({required this.triangles, required this.revision});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final seam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 0.7;
    final path = Path();
    for (final t in triangles) {
      final argb = t.color.toArgb();
      paint.color = Color(argb);
      seam.color = Color(argb);
      path
        ..reset()
        ..moveTo(t.ax, t.ay)
        ..lineTo(t.bx, t.by)
        ..lineTo(t.cx, t.cy)
        ..close();
      canvas.drawPath(path, paint);
      // A hairline stroke of the same colour closes the sub-pixel gaps between
      // adjacent triangles, which a pure-Dart fill otherwise shows as seams
      // across the plate.
      canvas.drawPath(path, seam);
    }
  }

  @override
  bool shouldRepaint(GlbTargetOverlayPainter old) =>
      old.revision != revision || old.triangles.length != triangles.length;
}

/// The reason a model failed to load, shown where the guidance lives rather than
/// on a separate diagnostics screen.
class GlbRenderFailureBanner extends StatelessWidget {
  const GlbRenderFailureBanner({super.key, required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xCC0F1418),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFF2A93B), width: 1),
    ),
    child: Row(
      children: <Widget>[
        const Icon(Icons.threed_rotation, size: 18, color: Color(0xFFF2A93B)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '3D target unavailable — showing the flat marker. $reason',
            style: const TextStyle(
              color: Color(0xFFAEB6BF),
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The flat 2D marker, in the state colour, sized for the `Positioned` wrapper
/// the overlay gives it.
///
/// Same shape the capture screen already draws (`_OrbPainter` in
/// `ar_capture_screen.dart`: a soft disc, a ring and a centre dot), so a load
/// failure degrades the guidance rather than removing it.
class _FlatTargetMarker extends StatelessWidget {
  const _FlatTargetMarker({required this.state});

  final ArTargetRenderState state;

  /// 132 dp — the aiming reticle's diameter, so the stand-in marker and the
  /// ring the user aims with are the same size. It was 102 dp, which made a
  /// degraded frame look like a different (smaller) target rather than the same
  /// one.
  static const double size = 132;

  @override
  Widget build(BuildContext context) {
    final rgb = state.bezelColor;
    // `.fromRGBO` takes a 0…1 opacity, so [ArTargetRenderState.targetOpacity]
    // applies unchanged; `Color.fromARGB` would need an `int` clamp here.
    final color = Color.fromRGBO(rgb[0], rgb[1], rgb[2], state.targetOpacity);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _FlatMarkerPainter(color: color, checks: state.showChecks),
      ),
    );
  }
}

class _FlatMarkerPainter extends CustomPainter {
  const _FlatMarkerPainter({required this.color, required this.checks});

  final Color color;
  final bool checks;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.18));
    // A dark outline behind the state ring, so a pale marker on a pale wall is
    // still a marker rather than a smudge.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );
    canvas.drawCircle(
      c,
      r * 0.34,
      Paint()..color = color.withValues(alpha: 0.55),
    );
    if (checks) {
      final check = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        c + Offset(-r * 0.34, 0),
        c + Offset(-r * 0.08, r * 0.26),
        check,
      );
      canvas.drawLine(
        c + Offset(-r * 0.08, r * 0.26),
        c + Offset(r * 0.36, -r * 0.3),
        check,
      );
    }
  }

  @override
  bool shouldRepaint(_FlatMarkerPainter old) =>
      old.color != color || old.checks != checks;
}
