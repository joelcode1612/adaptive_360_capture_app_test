/// The 3D AR target and its frame, specified from the prototype's two GLB
/// models.
///
/// Source of truth: `ar_capture_target.glb` and `white_frame_bezel.glb`, shipped
/// byte-for-byte in `assets/models/`. Everything here is plain data and an
/// abstract interface, so the behaviour (exact dimensions, per-state colour,
/// check visibility) is pinned by the plain-`dart` suite without a device.
///
/// Drawing them over the camera preview does **not** need a native
/// Sceneform/filament renderer: `platform/glb/` parses both files and projects
/// their real triangles in pure Dart, and
/// `presentation/overlays/glb_target_overlay.dart` implements [ArTargetRenderer]
/// against them. The bounds below are that renderer's acceptance criteria — it
/// asserts the parsed models still match them before drawing anything, so a
/// changed asset fails loudly instead of silently drawing a wrong marker.
library;

/// Asset path of the AR target marker, relative to the app bundle.
///
/// Must stay the path `pubspec.yaml` registers; `test/glb_checks.dart` reads the
/// same file from disk and compares its parsed bounds to [ArTargetModel].
const String arTargetAssetPath = 'assets/models/ar_capture_target.glb';

/// Asset path of the white frame bezel around the target.
const String arBezelAssetPath = 'assets/models/white_frame_bezel.glb';

/// How much larger the target is **drawn** than its specified size.
///
/// The plate is authored at 0.22 m across and planted 1.0 m down the aim ray, so
/// on a phone it covers roughly a quarter of the viewfinder width — small enough
/// that the earlier device runs described it as hard to find. 1.35 is the low
/// end of the brief's 30–50 % band and is applied **only at render time**:
///
/// * the anchor and the model matrix are untouched, so the marker stays exactly
///   on its computed world position;
/// * the alignment tolerance, the angular error and the capture trigger are
///   angular and never read this value;
/// * the plate and its bezel scale together, so they stay coplanar.
///
/// Anything that needs the marker's *specified* size must use
/// `CaptureGeometryConfig.targetDiameterM`, not this constant.
const double kArTargetDisplayScale = 1.35;

/// Native dimensions of [arTargetAssetPath], in metres, from its glTF accessor
/// bounds — **verified against the asset's own vertices, not assumed**:
///
/// * mesh 0 — white base plate, bounding box ≈ 0.54 × 0.54 × 0.006 m. It is a
///   **disc**, not a square: all 130 vertices sit at either `r = 0` (the hub)
///   or `r = 0.27` (the rim) — no corner vertices exist;
/// * mesh 1 — green centre, bounding box ≈ 0.20 × 0.20 × 0.012 m. Also a
///   **disc** (130 vertices, rim at `r = 0.10`), raised 6 mm above the plate;
/// * meshes 2 & 3 — the two check marks (8 vertices each, turned white, shown
///   only on `done`).
class ArTargetModel {
  /// The base plate half-extent (0.27 m), so the full plate is ~0.54 m. The
  /// plate is a disc of this radius — the box is a bounding box, not a shape.
  static const double baseHalfExtentM = 0.27;

  /// The circular centre's half-extent (0.10 m). Its bounding box is
  /// 0.20 × 0.20, but the mesh itself is a disc: every rim vertex lies at
  /// `r = 0.10`, so describing it as a square (as this doc once did) is wrong
  /// and misleads anyone reasoning about the frame's opening.
  static const double centerHalfExtentM = 0.10;

  /// How far the check meshes sit above the plate (≈ 0.012–0.018 m).
  static const double checkLiftM = 0.015;
}

/// Native dimensions of [arBezelAssetPath], in metres (≈ 0.70 × 0.70 × 0.012).
class ArBezelModel {
  static const double halfExtentM = 0.35;
}

/// The visual state of the target, mapped 1:1 from the prototype's capture
/// guidance state. The colours are the prototype's own:
/// * fail → amber `#f2a93b`;
/// * align / cap / done → green tint `#d8f6e3`;
/// * anything else (init / search) → white `#f4f4f4`.
enum ArTargetVisualState { idle, aligned, capturing, done, failed }

/// The colour the bezel takes for each [ArTargetVisualState], as a 24-bit RGB
/// triple (the prototype's hex values, with no alpha).
class ArTargetColors {
  static const List<int> idle = <int>[0xf4, 0xf4, 0xf4]; // #f4f4f4
  static const List<int> aligned = <int>[0xd8, 0xf6, 0xe3]; // #d8f6e3
  static const List<int> failed = <int>[0xf2, 0xa9, 0x3b]; // #f2a93b

  static List<int> forState(ArTargetVisualState s) => switch (s) {
    ArTargetVisualState.idle => idle,
    ArTargetVisualState.aligned => aligned,
    ArTargetVisualState.capturing => aligned,
    ArTargetVisualState.done => aligned,
    ArTargetVisualState.failed => failed,
  };
}

/// What the renderer must do each frame, derived from the guidance state.
///
/// Ported from the prototype's `glUpd()`:
/// * the target is always visible (the base plate + centre);
/// * the two check meshes are visible **only** when [ArTargetVisualState.done];
/// * the bezel colour follows [ArTargetColors.forState];
/// * the target's opacity drops to 0.75 when it is outside the view frustum
///   ([outOfView]).
class ArTargetRenderState {
  final ArTargetVisualState state;
  final bool outOfView;

  const ArTargetRenderState({required this.state, this.outOfView = false});

  /// White check marks are shown only on the `done` state.
  bool get showChecks => state == ArTargetVisualState.done;

  /// Target material opacity; 0.75 when out of view, 1 otherwise.
  double get targetOpacity => outOfView ? 0.75 : 1.0;

  /// The bezel colour for this state (24-bit RGB triple).
  List<int> get bezelColor => ArTargetColors.forState(state);
}

/// The interface that drives the target each frame.
///
/// Implemented by `GlbTargetScene` (pure Dart, testable) and by the
/// `GlbTargetRenderer` widget adapter, which paints the two GLBs over the camera
/// preview. Place the target at the current aim point, tint the bezel, and toggle
/// the check marks.
abstract class ArTargetRenderer {
  /// Shows or hides the whole target+bezel group.
  void setVisible(bool visible);

  /// Positions the target in the AR view: [screenX]/[screenY] in logical
  /// pixels (the prototype's `W/2 + dy*PX`), [scale] a 1-based factor, and
  /// [rotXDeg]/[rotYDeg] the head-tilt rotation that makes the marker sit
  /// upright as the phone moves.
  void placeTarget({
    required double screenX,
    required double screenY,
    required double scale,
    required double rotXDeg,
    required double rotYDeg,
  });

  /// Applies [ArTargetRenderState] (bezel colour, check visibility, opacity).
  void apply(ArTargetRenderState state);
}
