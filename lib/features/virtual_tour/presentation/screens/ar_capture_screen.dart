import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/guidance/projection.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/commercial_plan.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_guidance.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/capture_copy.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/capture_flow_engine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/capture_startup.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/flow_state.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/overlays/glb_target_overlay.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/widgets/camera_feed.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/widgets/flow_widgets.dart';

/// A placeholder for the guidance sub-line when no session exists yet (only the
/// `init`/`fail` states ignore this; a live session always has a target).
final PlanFrame _guidanceFallbackFrame = plan26().frames.first;

/// Screens 5 and 6: the guided capture, and the spherical progress map.
///
/// Ported from `V[5]`, `V[6]`, `mapSheet()` and `ovl()` of
/// `360° Capture Prototype.html`, with one deliberate difference.
///
/// **The prototype positions its target with CSS; this projects it.** The
/// prototype pans a background image by `yaw * PX` and moves a `.orb` div to
/// `W/2 + dy*PX`, i.e. a linear map from angle to pixels that is only correct
/// for a small field of view. The brief requires the real thing: take the
/// target's unit direction, rotate it into the camera frame with the camera's
/// own quaternion, and place the marker with the pinhole model using the
/// intrinsics ARCore reported. That is what [project] does, and it is why a
/// target near the edge of a wide-angle view lands in the right place here and
/// would not in the prototype.
///
/// The marker is the shipped `ar_capture_target.glb` and
/// `white_frame_bezel.glb`, rasterised over the feed by [GlbTargetOverlay] from
/// that projection — brief §6 asks for the original assets in the camera
/// guidance, not on a separate model viewer. The prototype's flat `.orb` is what
/// the overlay falls back to when the assets cannot load or when the target is
/// behind the camera, so guidance never depends on the renderer.
///
/// Everything else — the instruction wording, the edge clamping, the ring that
/// fills while capturing, the "not marked as done" message on a failure, the two
/// overlays — is the prototype's behaviour.
class ArCaptureScreen extends StatefulWidget {
  const ArCaptureScreen({super.key, required this.controller});

  final dynamic controller;

  @override
  State<ArCaptureScreen> createState() => _ArCaptureScreenState();
}

class _ArCaptureScreenState extends State<ArCaptureScreen> {
  CaptureFlowEngine get engine => widget.controller.engine;

  /// The two shipped `.glb` models, drawn over the feed.
  ///
  /// The screen owns it because the renderer is a [Listenable] the overlay
  /// repaints from, and the engine only ever pushes *state* into it
  /// (`arTargetRenderer?.apply(...)`) — the position comes from the projection
  /// below, which needs the viewport, which only the widget layer has.
  late final GlbTargetRenderer _renderer;

  /// The startup sequence, and what it is waiting for.
  ///
  /// **This screen starts the capture session itself.** The navigation that
  /// brings the user here — station setup's "Set Station Here" — never called
  /// `beginCapture()`, the only place `engine.session` is created, and this
  /// screen's old answer to a null session was an unbounded spinner with no
  /// text: the flow stopped at "initialise AR tracking" forever. Starting the
  /// session here covers every entry, guards against a double start, and gives
  /// the wait a name, a budget and two ways out.
  final CaptureStartupState _startup = CaptureStartupState();
  Timer? _watchdog;
  bool _sessionStartInFlight = false;
  bool _trackingLogged = false;

  /// The last observed live-session signature, so a 4 Hz watchdog does not
  /// repaint the whole camera screen when nothing changed.
  String? _lastSignature;

  @override
  void initState() {
    super.initState();
    _renderer = GlbTargetRenderer.load();
    engine.arTargetRenderer = _renderer;
    // Post-frame: `beginCapture()` opens the camera, and a build-phase call
    // that opens hardware mid-layout is how you get a surface storm.
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginStartup());
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    // Only clear the seam if it is still ours, and always drop the listener the
    // overlay registered.
    if (identical(engine.arTargetRenderer, _renderer)) {
      engine.arTargetRenderer = null;
    }
    _renderer.dispose();
    super.dispose();
  }

  // ── the startup sequence ───────────────────────────────────────────────

  void _beginStartup() {
    if (!mounted) return;
    CaptureStartMarkers.log(
      CaptureStartMarkers.entered,
      'capture screen entered',
      _startup.enteredAt,
    );
    if (engine.session != null) {
      // Reached from a path that already started the session (a retry, the
      // review screen). The watchdog still owns the wait for the first pose.
      _startup.markSessionCreated();
      _startWatchdog();
      setState(() {});
      return;
    }
    _startSession();
  }

  /// Starts the session, exactly once at a time.
  ///
  /// The in-flight flag is the guard the brief asks for: a second tap on Retry
  /// while the first `beginCapture()` is still opening the camera must not
  /// create a second session, and a camera that fails must not be re-opened in
  /// a tight loop.
  Future<void> _startSession() async {
    if (_sessionStartInFlight || !mounted) return;
    _sessionStartInFlight = true;
    _startup.markSessionRequested();
    CaptureStartMarkers.log(
      CaptureStartMarkers.sessionRequested,
      'beginCapture() called',
      _startup.enteredAt,
    );
    if (mounted) setState(() {});
    try {
      await engine.beginCapture();
      if (!mounted) return;
      if (engine.session == null) {
        _failStartup(
          stalledIn: CaptureStartStage.startingSession,
          reason: engine.fatal ?? 'the session was not created',
        );
        return;
      }
      _startup.markSessionCreated();
      CaptureStartMarkers.log(
        CaptureStartMarkers.sessionCreated,
        'session exists',
        _startup.enteredAt,
      );
    } catch (e, st) {
      debugPrint('beginCapture threw: $e\n$st');
      if (!mounted) return;
      _failStartup(reason: 'the capture session failed', thrown: e);
    } finally {
      _sessionStartInFlight = false;
    }
    if (mounted) setState(() {});
    _startWatchdog();
  }

  /// Watches the startup stages until tracking is real or a bounded wait
  /// expires. 250 ms: responsive enough to read as live, slow enough that a
  /// camera opening in two seconds does not tear.
  void _startWatchdog() {
    _watchdog ??= Timer.periodic(
      const Duration(milliseconds: 250),
      _onWatchdog,
    );
  }

  void _onWatchdog(Timer _) {
    if (!mounted) return;
    final session = engine.session;
    _startup.observe(
      hasSession: session != null,
      hasTargets: session != null && session.targets.isNotEmpty,
      hasPose: engine.poseSource.latest != null,
    );

    final signature =
        '${_startup.stage}/${session != null}/'
        '${session?.targets.length ?? -1}/${engine.poseSource.latest != null}';
    final panelVisible = session == null || _startup.isFailed;

    if (_startup.isTracking && !_trackingLogged) {
      _trackingLogged = true;
      CaptureStartMarkers.log(
        CaptureStartMarkers.trackingLive,
        'first pose is driving the capture plan',
        _startup.enteredAt,
      );
      _watchdog?.cancel();
      _watchdog = null;
    }

    final stalled = _startup.stalledStage(DateTime.now());
    if (stalled != null) {
      _failStartup(stalledIn: stalled, reason: _stallReason(stalled));
    }

    // While the panel is up, every tick repaints for the elapsed counter.
    // Once the live view is showing, repaint only on real change — a camera
    // screen that rebuilds four times a second for a counter nobody sees is
    // the excessive setState the brief forbids.
    if (panelVisible || signature != _lastSignature) {
      _lastSignature = signature;
      setState(() {});
    }
  }

  /// What to say when a stage ran out of budget. Names the stage: "it timed
  /// out" with no stage is the generic spinner this replaces.
  String _stallReason(CaptureStartStage stage) => switch (stage) {
    CaptureStartStage.startingSession =>
      'the session did not start in time — the camera may still be opening, '
          'or another app may be holding it',
    CaptureStartStage.waitingForPose =>
      'no camera direction arrived — the motion sensors never reported a '
          'pose, so AR tracking never initialised',
    _ => 'startup stalled',
  };

  void _failStartup({
    required String reason,
    CaptureStartStage? stalledIn,
    Object? thrown,
  }) {
    _startup.fail(reason, stalledIn: stalledIn, thrown: thrown);
    CaptureStartMarkers.log(
      CaptureStartMarkers.failed,
      _startup.error ?? 'startup failed',
      _startup.enteredAt,
    );
  }

  void _retryStartup() {
    _trackingLogged = false;
    _startup.retry();
    _startSession();
  }

  void _backToStationSetup() {
    _watchdog?.cancel();
    _watchdog = null;
    engine.endAr();
    widget.controller.goTo(CaptureScreen.stationSetup);
    widget.controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final session = engine.session;
    if (session == null || _startup.isFailed) {
      return _buildStartup();
    }

    return CameraScaffold(
      body: Column(
        children: [
          // `.sc` → `hd('Station N', '<span>Capture n of 26</span>')` → `.cam` →
          // `.ip`, in that order and with nothing else. The first port of this
          // screen had no header, which left the capture view with no way back
          // and put the count only in the panel below the viewfinder.
          FlowHeader(
            title: 'Station ${engine.currentStation + 1}',
            trailing: Text(
              'Capture '
              '${_captureNumber(engine.stations[engine.currentStation])} of '
              '${engine.stations[engine.currentStation].total}',
              style: const TextStyle(
                color: CaptureColors.headerMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            // The header's `‹` is the prototype's `back()`, which lands on the
            // station setup screen. Here it opens the pause sheet instead of
            // popping, because leaving this screen directly would discard the
            // frame being taken; the sheet's "Save and exit" is the same exit
            // with every accepted frame already on disk.
            onBack: () {
              engine.onInterruption();
              widget.controller.refresh();
            },
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraFeed(
                  camera: engine.activeCamera,
                  arOwnsSensor: engine.arRunning,
                  reason: engine.fatal,
                  manualHint: true,
                  onReopen: () async => widget.controller.reopenCamera(),
                ),
                // The prototype's `.frame`: a 10 dp inset rounded border, drawn
                // above the feed and below every guide so it never hides a
                // target.
                const IgnorePointer(
                  child: Padding(
                    padding: EdgeInsets.all(CaptureMetrics.viewfinderInset),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.fromBorderSide(
                          BorderSide(
                            color: CaptureColors.viewfinderFrame,
                            width: 1.5,
                          ),
                        ),
                        borderRadius: BorderRadius.all(
                          Radius.circular(CaptureMetrics.viewfinderRadius),
                        ),
                      ),
                    ),
                  ),
                ),
                _TargetOverlay(
                  engine: engine,
                  session: session,
                  renderer: _renderer,
                ),
                // `.bn` — the banner, inset from the right by the mini-map.
                if (_bannerText(engine) case final text?)
                  Positioned(
                    left: 12,
                    top: 12,
                    right: CaptureMetrics.bannerRightInset,
                    child: _Banner(
                      text: text,
                      color: CaptureColors.warn,
                      // `.bn` gets a 1 px amber rule except while AR is still
                      // initialising, which is a wait, not a warning.
                      bordered: switch (engine.guidance.state) {
                        CaptureGuidanceState.init => false,
                        _ => true,
                      },
                    ),
                  ),
                // `.mm` — the tappable 88 dp progress map.
                Positioned(
                  right: 12,
                  top: 12,
                  child: _MiniMap(
                    engine: engine,
                    controller: widget.controller,
                  ),
                ),
                if (engine.interrupted)
                  _PausedSheet(controller: widget.controller, engine: engine),
              ],
            ),
          ),
          _InstructionPanel(engine: engine, controller: widget.controller),
        ],
      ),
    );
  }

  /// The header's "Capture n of 26", which is `Math.min(done+1,26)` in the
  /// prototype — the *next* view, clamped so a finished station still reads 26.
  int _captureNumber(StationRecord record) =>
      math.min(record.capturedCount + 1, record.total);

  // ── the startup panel ──────────────────────────────────────────────────

  /// The wizard stage this wait belongs to, kept distinct as the brief
  /// requires: the session (STEP 3), the first valid pose (3A) and stable
  /// tracking (3B) are three different waits, and naming the one we are in is
  /// what turns a spinner into an answer.
  String get _stepLabel => switch (_startup.stage) {
    CaptureStartStage.entering ||
    CaptureStartStage.startingSession ||
    CaptureStartStage.failed => 'STEP 3 · INITIALISE AR',
    CaptureStartStage.waitingForPose => 'STEP 3A · WAIT FOR A VALID POSE',
    CaptureStartStage.tracking => 'STEP 3B · WAIT FOR STABLE TRACKING',
  };

  /// The staged wait that replaces the eternal spinner.
  ///
  /// Every element answers a question the spinner could not: which stage, how
  /// long, what is missing, and what to do next. **Retry** re-arms the failed
  /// stage (guarded, so it cannot double-start a session) and **Back** releases
  /// the camera and returns to the station setup. Neither can hang: both are
  /// plain callbacks, and the panel is always visible while anything is
  /// unresolved.
  Widget _buildStartup() {
    final now = DateTime.now();
    final failed = _startup.isFailed;
    final accent = failed ? CaptureColors.danger : CaptureColors.ok;

    return CameraScaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Text(
              _stepLabel,
              style: const TextStyle(
                color: CaptureColors.mutedOnDark,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (!failed) ...[
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    _startup.stage.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _startup.describe(now),
              style: const TextStyle(
                color: CaptureColors.bulletOnDark,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            // The engine's own sentence, when it has one. On the failure path
            // this is the specific reason; while waiting it is the guidance
            // status.
            if (engine.fatal case final fatal?) ...[
              const SizedBox(height: 10),
              Text(
                fatal,
                style: const TextStyle(
                  color: CaptureColors.danger,
                  fontSize: 13,
                ),
              ),
            ] else if (engine.warning case final warning?) ...[
              const SizedBox(height: 10),
              Text(
                warning,
                style: const TextStyle(color: CaptureColors.warn, fontSize: 13),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              engine.arTier.headline,
              style: const TextStyle(
                color: CaptureColors.mutedOnDark,
                fontSize: 12,
              ),
            ),
            const Spacer(),
            if (kDebugMode) ...[_debugDiagnostics(), const Spacer()],
            PrimaryButton(
              label: failed ? 'Try again' : 'Starting…',
              enabled: !_sessionStartInFlight,
              onPressed: _retryStartup,
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Back to station setup',
              onPressed: _backToStationSetup,
            ),
          ],
        ),
      ),
    );
  }

  /// Debug-only diagnostics: the numbers behind the wait.
  ///
  /// Production keeps the clean panel above; this compiles to nothing in
  /// release and prints nothing to any log or disk — it exists so a
  /// developer holding the phone can see *which* input is missing.
  Widget _debugDiagnostics() {
    final session = engine.session;
    final pose = engine.poseSource.latest;
    final elapsedMs = DateTime.now()
        .difference(_startup.enteredAt)
        .inMilliseconds;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CaptureColors.groupOnDark,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Diagnostics (debug build)',
            style: TextStyle(
              color: CaptureColors.headerMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          _diagRow('stage', '${_startup.stage.name} · $elapsedMs ms'),
          _diagRow(
            'session',
            session == null
                ? 'null — beginCapture() has not produced one'
                : 'live · ${session.targets.length} targets',
          ),
          _diagRow(
            'camera pose',
            pose == null
                ? 'null · ${_startup.consecutivePoseMisses} consecutive misses'
                : 'live · ${_startup.poseCount} poses seen',
          ),
          _diagRow(
            'capture progress',
            session == null
                ? '—'
                : '${session.currentTargetIndex + 1} of ${session.targets.length}',
          ),
          _diagRow('tier', engine.arTier.tier.name),
          _diagRow('fatal', engine.fatal ?? '—'),
          _diagRow('warning', engine.warning ?? '—'),
        ],
      ),
    );
  }

  Widget _diagRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Text(
      '$label: $value',
      style: const TextStyle(
        color: CaptureColors.mutedOnDark,
        fontSize: 11,
        fontFamily: 'monospace',
      ),
    ),
  );
}

/// The `.bn` banner's text, or `null` when the prototype would hide it.
///
/// The reference shows it in exactly three situations (`tick()`'s last line):
/// the machine is initialising, the capture failed, or the phone moved during a
/// capture. Drift and tracking-loss are this app's own additions and take
/// priority, because they explain a target that has stopped moving.
String? _bannerText(CaptureFlowEngine engine) {
  if (engine.driftGate.banner case final text?) return text;
  if (engine.trackingLost) {
    return 'AR cannot follow the room. Point the phone back towards where you '
        'started this station.';
  }
  return switch (engine.guidance.state) {
    CaptureGuidanceState.init => 'Initializing AR tracking…',
    CaptureGuidanceState.fail => 'Capture failed',
    CaptureGuidanceState.cap when engine.guidance.moving =>
      'Phone moving too much — hold steady',
    _ => null,
  };
}

/// The prototype's `.mm`: a live miniature of the 26-point map, tap to enlarge.
class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.engine, required this.controller});

  final CaptureFlowEngine engine;
  final dynamic controller;

  @override
  Widget build(BuildContext context) {
    final record = engine.stations[engine.currentStation];
    final session = engine.session;
    final done = record.capturedCount;
    final total = record.total;
    return Semantics(
      button: true,
      label:
          'Capture progress: $done of $total photographs saved. '
          'Open the progress map',
      child: SizedBox.square(
        dimension: CaptureMetrics.miniMapSize,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: CaptureColors.cameraChrome.withValues(alpha: 0.82),
            padding: const EdgeInsets.all(5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CaptureMetrics.miniMapRadius),
              side: const BorderSide(color: CaptureColors.hairlineChip),
            ),
          ),
          onPressed: () => controller.goTo(CaptureScreen.progressMap),
          child: ExcludeSemantics(
            child: SphereProgressMap(
              frames: record.plan.frames,
              statuses: record.statuses,
              currentIndex: session == null || session.targets.isEmpty
                  ? null
                  : session.currentTargetIndex,
              size: CaptureMetrics.miniMapSize - 10,
              // The prototype's miniature draws the target cloud faintly and the
              // plan dots on top; at 78 dp the cloud is noise, so it stays off.
              showSamples: false,
            ),
          ),
        ),
      ),
    );
  }
}

/// The target: projected with the pinhole model, then drawn by the glTF
/// renderer, with the prototype's guide line and shutter ring over it.
class _TargetOverlay extends StatelessWidget {
  const _TargetOverlay({
    required this.engine,
    required this.session,
    required this.renderer,
  });

  final CaptureFlowEngine engine;
  final CaptureSession session;
  final GlbTargetRenderer renderer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (session.targets.isEmpty) return const SizedBox.shrink();
      final target = session.current.frame;

      // The camera's orientation as a unit quaternion, which is what the brief
      // requires the projection to use. Yaw and pitch are derived for the
      // readout only. The fallback reconstructs a roll-free quaternion, which is
      // correct for the simulated path and slightly wrong for a rolled phone —
      // noted in the device checklist.
      final q =
          session.sensorSource?.sensedOrientation() ??
          Quat.fromYawPitch(
            session.displayPose.yawDeg,
            session.displayPose.pitchDeg,
          );

      final dc = toCameraFrame(q, target.direction);
      final p = project(
        dc,
        constraints.maxWidth,
        constraints.maxHeight,
        session.params.hfovDeg,
        session.params.vfovDeg,
      );

      // The guide line, the ring and the target colour are keyed to the
      // prototype's 6-state guidance, not the machine phase: green for
      // align/cap/done, the line hidden for cap/done/fail/init, and the ring
      // filling only while capturing. A failed capture stays warn (the bezel is
      // what turns amber), exactly as the prototype.
      final g = engine.guidance;
      final orbAligned =
          g.state == CaptureGuidanceState.align ||
          g.state == CaptureGuidanceState.cap ||
          g.state == CaptureGuidanceState.done;
      final color = orbAligned ? CaptureColors.ok : CaptureColors.warn;
      final hideLine =
          g.state == CaptureGuidanceState.cap ||
          g.state == CaptureGuidanceState.done ||
          g.state == CaptureGuidanceState.fail ||
          g.state == CaptureGuidanceState.init;
      final progress = g.state == CaptureGuidanceState.cap
          ? g.capProgress
          : 0.0;

      // Report whether the target is outside the central region, so the engine
      // can dim the marker and show the "outside the view" line. Approximates
      // the prototype's `tx<51||tx>W-51||ty<51||ty>H-51` as a fraction of the
      // viewport (51 on a 344×544 screen).
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final outside =
          !p.onScreen ||
          p.u < w * 0.148 ||
          p.u > w - w * 0.148 ||
          p.v < h * 0.094 ||
          p.v > h - h * 0.094;
      engine.setOutOfView(outside);

      // Give the renderer the same point the projection produced before it
      // builds, so the 3D marker, the flat fallback that stands in for it, and
      // the guide line below cannot end up on three different places.
      renderer.setPlacement(screenX: p.u, screenY: p.v);

      return Stack(
        children: [
          // The line from the centre to the marker, hidden once the shutter is
          // about to fire so it does not obscure the frame.
          if (!hideLine)
            Positioned.fill(
              child: CustomPaint(
                painter: _GuideLinePainter(
                  to: Offset(p.u, p.v),
                  color: color,
                  behind: !p.onScreen,
                ),
              ),
            ),
          GlbTargetOverlay(
            renderer: renderer,
            cameraPose: q,
            hfovDeg: session.params.hfovDeg,
            vfovDeg: session.params.vfovDeg,
          ),
          // The shutter countdown has no 3D counterpart in either asset, so it
          // stays a ring around the target — the prototype's `#pr` dashoffset.
          if (progress > 0 && progress < 1)
            Positioned(
              left: p.u - CaptureColors.orbSize / 2,
              top: p.v - CaptureColors.orbSize / 2,
              child: _ProgressRing(color: color, progress: progress),
            ),
        ],
      );
    },
  );
}

class _GuideLinePainter extends CustomPainter {
  _GuideLinePainter({
    required this.to,
    required this.color,
    required this.behind,
  });

  final Offset to;
  final Color color;

  /// True when the target is behind the camera. The marker is clamped to the
  /// screen edge and the line is dashed, because a target behind you is a
  /// "turn around", not a "look here".
  final bool behind;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color.withValues(alpha: behind ? 0.5 : 0.9)
      ..strokeWidth = 2;
    if (behind) {
      const dash = 10.0;
      final total = (to - centre).distance;
      if (total <= 0) return;
      final dir = (to - centre) / total;
      for (var d = 0.0; d < total; d += dash * 2) {
        canvas.drawLine(
          centre + dir * d,
          centre + dir * (d + dash).clamp(0.0, total),
          paint,
        );
      }
    } else {
      canvas.drawLine(centre, to, paint);
    }
  }

  @override
  bool shouldRepaint(_GuideLinePainter old) =>
      old.to != to || old.color != color || old.behind != behind;
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.color, required this.progress});

  final Color color;

  /// Capture progress, 0…1.
  final double progress;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: CaptureColors.orbSize,
    height: CaptureColors.orbSize,
    child: CustomPaint(
      painter: _ProgressRingPainter(color: color, progress: progress),
    ),
  );
}

class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      progress * 2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) =>
      old.color != color || old.progress != progress;
}

/// The prototype's `.bn` — a small dark chip over the top-left of the
/// viewfinder. Its right inset keeps it clear of `.mm`.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.color,
    required this.bordered,
  });

  final String text;
  final Color color;

  /// `.bn` is normally borderless; `tick()` adds `1px solid AM` for every
  /// message except the initialising one.
  final bool bordered;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: text,
    child: ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: CaptureColors.cameraChrome.withValues(alpha: 0.88),
          border: bordered ? Border.all(color: color, width: 1.4) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              bordered ? Icons.warning_amber_rounded : Icons.autorenew,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The instruction footer under the viewfinder.
///
/// The reference's AR page is a dark camera stage with a **white** footer
/// (`.native-footer{background:white}`): one headline, one line of detail, the
/// hold progress, and only the action the current state actually offers. The
/// previous port kept the whole chrome dark, which is why this screen did not
/// read as SiteWise.
///
/// **What never hides, and why.** The block reason stays on screen in every
/// state. A footer that hides *why* the shutter is waiting would be a progress
/// bar with no explanation. The technical readout (`yaw −12° · pitch +4° ·
/// error 3.2°`) moved into the collapsible detail instead of the headline: it is
/// a diagnostic, not an instruction.
class _InstructionPanel extends StatelessWidget {
  const _InstructionPanel({required this.engine, required this.controller});

  final CaptureFlowEngine engine;
  final dynamic controller;

  @override
  Widget build(BuildContext context) {
    final session = engine.session;
    final record = engine.stations[engine.currentStation];
    final g = engine.guidance;
    final target = session == null || session.targets.isEmpty
        ? null
        : session.current.frame;

    // The 6-state guidance drives the headline and the detail line via
    // `flow/capture_copy.dart`, so the plain-`dart` suite can pin them. The
    // banner text is no longer here — `.bn` puts it over the viewfinder instead.
    var dy = 0.0;
    var dp = 0.0;
    if (target != null && session != null) {
      final head = session.displayPose;
      final e = guidanceErrorDeg(
        headYawDeg: head.yawDeg,
        headPitchDeg: head.pitchDeg,
        targetYawDeg: target.yawDeg,
        targetPitchDeg: target.pitchDeg,
      );
      dy = e.yawRightDeg;
      dp = e.pitchUpDeg;
    }
    final title = guidanceTitle(
      g.state,
      searchDirection: searchDirection(dy, dp),
    );
    final sub = guidanceSub(
      g.state,
      target ?? _guidanceFallbackFrame,
      outOfView: g.outOfView,
    );

    final hold = g.state == CaptureGuidanceState.cap ? g.capProgress : 0.0;
    final tone = _footerTone(g.state);
    final failed = g.state == CaptureGuidanceState.fail;

    return Material(
      color: SiteWiseColors.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(CaptureMetrics.footerRadius),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _FooterPill(label: tone.label, color: tone.color),
                  const Spacer(),
                  Text(
                    progressLine(
                      captured: record.capturedCount,
                      total: record.total,
                      skipped: record.skippedCount,
                    ),
                    style: const TextStyle(
                      color: SiteWiseColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // The one instruction. A live region so a screen reader announces
              // the transitions ("Target aligned — hold still") and nothing
              // else; the camera frame itself is never announced.
              Semantics(
                liveRegion: true,
                label: '$title. $sub',
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: SiteWiseColors.ink,
                          fontSize: 20,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: SiteWiseColors.muted,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Hold / capture progress. Always present so the bar does not
              // appear from nowhere when alignment starts; empty until the hold
              // is actually accumulating.
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: hold.clamp(0.0, 1.0),
                  minHeight: 7,
                  backgroundColor: CaptureColors.trackOnLight,
                  valueColor: AlwaysStoppedAnimation<Color>(tone.color),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      failed
                          ? 'This view is not marked as done. Retry when the '
                                'marker is back in the circle.'
                          : hold > 0
                          ? 'Taking photo…'
                          : 'Hold the marker inside the circle.',
                      maxLines: 2,
                      style: TextStyle(
                        color: failed
                            ? CaptureColors.warnOnLight
                            : SiteWiseColors.muted,
                        fontSize: 12,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (failed || engine.manualCaptureOffered) ...[
                    const SizedBox(width: 12),
                    _FooterAction(
                      label: failed ? 'Retry' : 'Capture anyway',
                      onPressed: () {
                        if (failed) {
                          engine.retryFailed();
                        } else {
                          engine.manualCapture();
                        }
                        controller.refresh();
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The footer's state pill: what the capture engine is doing, in words.
({String label, Color color}) _footerTone(CaptureGuidanceState state) =>
    switch (state) {
      CaptureGuidanceState.init => (
        label: 'Starting camera',
        color: SiteWiseColors.muted,
      ),
      CaptureGuidanceState.search => (
        label: 'Find the target',
        color: CaptureColors.primary,
      ),
      CaptureGuidanceState.align => (
        label: 'Aligned',
        color: CaptureColors.okOnLight,
      ),
      CaptureGuidanceState.cap => (
        label: 'Taking photo',
        color: CaptureColors.okOnLight,
      ),
      CaptureGuidanceState.done => (
        label: 'Photo saved',
        color: CaptureColors.okOnLight,
      ),
      CaptureGuidanceState.fail => (
        label: 'Capture failed',
        color: CaptureColors.warnOnLight,
      ),
    };

/// A soft-tinted pill on the white footer — `.pill` in the reference.
class _FooterPill extends StatelessWidget {
  const _FooterPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(100),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    ),
  );
}

/// The one action the footer offers, as the reference's `.btn`.
class _FooterAction extends StatelessWidget {
  const _FooterAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: CaptureColors.primary,
      foregroundColor: Colors.white,
      overlayColor: CaptureColors.primaryPressed,
      minimumSize: const Size(96, CaptureMetrics.minTouchTarget),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    child: Text(label),
  );
}

/// The prototype's `.shd cen` / `.sht` — the "Capture paused" sheet.
class _PausedSheet extends StatelessWidget {
  const _PausedSheet({required this.controller, required this.engine});

  final dynamic controller;
  final CaptureFlowEngine engine;

  @override
  Widget build(BuildContext context) {
    final record = engine.stations[engine.currentStation];
    return Container(
      color: CaptureColors.scrim,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: CaptureColors.sheet,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Capture paused',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Your ${record.capturedCount} captured photos are saved. Resume '
              'where you stopped — nothing is repeated.',
              style: const TextStyle(
                color: CaptureColors.mutedOnDark,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Resume',
              onPressed: () => controller.resumeAfterInterruption(),
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Save and exit',
              onPressed: () => controller.saveAndExit(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Screen 6: the spherical progress map.
class ProgressMapScreen extends StatelessWidget {
  const ProgressMapScreen({super.key, required this.controller});

  final dynamic controller;

  CaptureFlowEngine get engine => controller.engine;

  @override
  Widget build(BuildContext context) {
    final record = engine.stations[engine.currentStation];
    final session = engine.session;
    final current = session == null || session.targets.isEmpty
        ? null
        : session.currentTargetIndex;

    int ringDone(double from, double to) {
      var n = 0;
      for (var i = 0; i < record.plan.frames.length; i++) {
        final f = record.plan.frames[i];
        if (f.isPole) continue;
        if (f.pitchDeg >= from && f.pitchDeg < to) {
          if (i < record.statuses.length &&
              record.statuses[i] == TargetStatus.ok) {
            n++;
          }
        }
      }
      return n;
    }

    int ringTotal(double from, double to) {
      var n = 0;
      for (final f in record.plan.frames) {
        if (f.isPole) continue;
        if (f.pitchDeg >= from && f.pitchDeg < to) n++;
      }
      return n;
    }

    final poles = record.plan.frames.where((f) => f.isPole).toList();
    final polesDone = poles
        .where(
          (f) =>
              f.index < record.statuses.length &&
              record.statuses[f.index] == TargetStatus.ok,
        )
        .length;

    return FlowScaffold(
      // Progress is one of the reference's white screens: a map, a count and a
      // ring breakdown, read at a glance rather than aimed with.
      onLight: true,
      title: 'Capture ${record.capturedCount} of ${record.total}',
      onBack: () => controller.goTo(CaptureScreen.arCapture),
      body: Column(
        children: [
          const SizedBox(height: 6),
          Center(
            child: SphereProgressMap(
              frames: record.plan.frames,
              statuses: record.statuses,
              currentIndex: current,
              size: 260,
              onLight: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${record.capturedCount} completed · '
            '${current == null ? 'no target' : 'now on view ${current + 1}'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: SiteWiseColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          for (final ring in progressRings)
            RingProgressRow(
              label: ring.label,
              done: ringDone(ring.fromPitchDeg, ring.toPitchDeg),
              total: ringTotal(ring.fromPitchDeg, ring.toPitchDeg),
              color: CaptureColors.okOnLight,
              onLight: true,
            ),
          RingProgressRow(
            label: 'Zenith / Nadir',
            done: polesDone,
            total: poles.length,
            color: CaptureColors.okOnLight,
            onLight: true,
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: SiteWiseColors.softBlue,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: SiteWiseColors.borderStrong),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: SiteWiseColors.primary,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This map shows capture progress. It is not the AR target in '
                    'the camera view — the ring breakdown is by pitch band, not '
                    'by the order you capture in.',
                    style: TextStyle(
                      color: Color(0xFF1E3A8A),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      footer: PrimaryButton(
        label: 'Back to the camera',
        onPressed: () => controller.goTo(CaptureScreen.arCapture),
      ),
    );
  }
}
