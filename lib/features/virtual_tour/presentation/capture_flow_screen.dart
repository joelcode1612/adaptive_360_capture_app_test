import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/flow_state.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_flow_controller.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/ar_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/plan_screens.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/review_screens.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/station_setup_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/widgets/flow_widgets.dart';

/// The capture flow, screens 1–9 of `360° Capture Prototype.html`.
///
/// One host with a switch over [CaptureScreen] rather than nine routes. The
/// flow is a wizard: the screens share a controller, a session and a state
/// machine, and pushing each one onto the navigator would mean either threading
/// the controller through every `MaterialPageRoute` or reaching for a global.
/// The prototype's `go(n)` is a screen index, and this keeps that shape.
///
/// Screens 1–5 are the real screens. Screens 6 and 9 — the progress map and the
/// tour preview — are promoted from the prototype's sheets to full screens so
/// each screen group is reachable and testable on its own; the progress map is
/// still also available as a sheet over the camera, which is where the prototype
/// puts it.
class CaptureFlowScreen extends StatefulWidget {
  const CaptureFlowScreen({super.key, this.controller, this.autoStart = true});

  /// Injected by a test. When `null` the screen builds the real one, which
  /// needs the platform's camera, AR and storage.
  final CaptureFlowController? controller;

  /// Whether to build the controller on the first frame. A test that injects
  /// one sets this false.
  final bool autoStart;

  @override
  State<CaptureFlowScreen> createState() => _CaptureFlowScreenState();
}

class _CaptureFlowScreenState extends State<CaptureFlowScreen>
    with WidgetsBindingObserver {
  CaptureFlowController? _controller;
  String? _bootError;
  bool _booting = false;

  CaptureFlowController? get _c => _controller ?? widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      _controller = widget.controller;
      // The listener is what makes the host follow the flow. Built here rather
      // than left to `_boot`, which returns immediately for an injected
      // controller: without it the screen keeps painting screen 1 no matter
      // where the flow goes, and a test that injects one — the documented way
      // of reaching these widgets — would be checking a layout that never
      // changes.
      _controller!.addListener(_onFlowChanged);
    } else if (widget.autoStart) {
      _boot();
    }
  }

  Future<void> _boot() async {
    if (_booting || _controller != null) return;
    _booting = true;
    try {
      final created = await CaptureFlowController.create();
      if (!mounted) {
        created.dispose();
        return;
      }
      setState(() => _controller = created);
      created.addListener(_onFlowChanged);
      created.syncTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootError = '$e');
    } finally {
      _booting = false;
    }
  }

  void _onFlowChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        c.onAppPaused();
      case AppLifecycleState.resumed:
        c.onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onFlowChanged);
    // Only dispose what this widget created. An injected controller belongs to
    // its owner.
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  /// Re-arms the boot after a failure. The controller is still null, so
  /// `_boot()` runs again rather than returning early.
  void _retryBoot() {
    if (!mounted) return;
    setState(() => _bootError = null);
    _boot();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_bootError != null) {
      return _BootFailure(message: _bootError!, onRetry: _retryBoot);
    }
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Every screen is dark: in the prototype the whole app lives inside one dark
    // phone shell, so there is no light variant to fall back to. The capture
    // screen gets the other theme for exactly one reason — its scaffold has to
    // be transparent so an AR session's camera surface shows through behind the
    // Flutter view.
    final cameraScreen = c.screen == CaptureScreen.arCapture;
    final flow = PopScope(
      canPop: !cameraScreen,
      onPopInvokedWithResult: (didPop, _) {
        // The capture screen has no back: leaving mid-station without saving
        // would discard frames the machine has already validated. The sheet on
        // that screen offers Resume and Save and exit instead.
        if (!didPop) c.onAppPaused();
      },
      child: _screenFor(c),
    );
    return cameraScreen ? Theme(data: captureCameraTheme(), child: flow) : flow;
  }

  Widget _screenFor(CaptureFlowController c) => switch (c.screen) {
    CaptureScreen.intro => IntroScreen(controller: c),
    CaptureScreen.roomDetails => RoomDetailsScreen(controller: c),
    CaptureScreen.plan => PlanScreen(controller: c),
    CaptureScreen.stationSetup => StationSetupScreen(controller: c),
    CaptureScreen.arCapture => ArCaptureScreen(controller: c),
    CaptureScreen.progressMap => ProgressMapScreen(controller: c),
    CaptureScreen.stationReview => StationReviewScreen(controller: c),
    CaptureScreen.addStation => AddStationScreen(controller: c),
    CaptureScreen.tourPreview => TourPreviewScreen(controller: c),
  };
}

/// Shown when the flow could not even be built.
///
/// Not a crash screen: the most likely cause is a device with no usable camera,
/// which is a supported configuration and gets an explanation, not a stack
/// trace.
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.message, this.onRetry});

  /// The raw exception. It is **not** the main message: a user cannot act on a
  /// stack-trace string, so it is kept behind a disclosure and the screen leads
  /// with what happened and what to do about it.
  final String message;

  final VoidCallback? onRetry;

  /// A sentence about the likely cause, chosen from the exception's own words.
  String get _explanation {
    final m = message.toLowerCase();
    if (m.contains('permission') || m.contains('denied')) {
      return 'SiteWise needs the camera to capture a station. Allow camera '
          'access in Android settings, then try again.';
    }
    if (m.contains('camera') || m.contains('in use')) {
      return 'The camera could not be opened. Another app may be using it — '
          'close the other app and try again.';
    }
    return 'The capture session could not start. Your saved stations are not '
        'affected.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: SiteWiseColors.paper,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: SiteWiseColors.softBlue,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.no_photography_outlined,
                    size: 28,
                    color: SiteWiseColors.primary,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Capture could not start',
                  style: TextStyle(
                    color: SiteWiseColors.ink,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _explanation,
                  style: const TextStyle(
                    color: SiteWiseColors.muted,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                if (onRetry != null) ...[
                  PrimaryButton(label: 'Try again', onPressed: onRetry),
                  const SizedBox(height: 8),
                ],
                SecondaryButton(
                  label: 'Close',
                  onPressed: () => Navigator.of(context).maybePop(),
                  onLight: true,
                ),
                const SizedBox(height: 14),
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text(
                      'Technical details',
                      style: TextStyle(
                        color: SiteWiseColors.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: SiteWiseColors.muted,
                            fontSize: 12,
                            height: 1.4,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
