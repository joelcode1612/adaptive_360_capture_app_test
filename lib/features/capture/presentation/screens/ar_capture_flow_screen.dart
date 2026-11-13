import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/capture/application/panorama_generation_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/data/datasources/opencv_panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/ar_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/capture_review_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The standalone 26-target workflow host: capture → validate → stitch →
/// review, the same hand-off FYP's `ArCaptureMobilePage` made — minus every
/// SiteWise piece (tour drafts, frame manifests, property ids). One station
/// lives under one `FileCaptureRepository` directory and the panorama is
/// stitched on device from its saved JPEGs.
///
/// [repository], [stationId] and [stitcher] exist for callers that already
/// hold them: the review screen's retake path reopens *this same station*
/// through them, and the tests inject a fake stitcher. A fresh launch from
/// the home screen leaves everything null and starts a new station.
class ArCaptureFlowScreen extends StatefulWidget {
  const ArCaptureFlowScreen({
    super.key,
    this.repository,
    this.stationId,
    this.stitcher,
  });

  final CaptureRepository? repository;
  final String? stationId;
  final PanoramaStitcher? stitcher;

  @override
  State<ArCaptureFlowScreen> createState() => _ArCaptureFlowScreenState();
}

/// The capture→stitch hand-off, isolated from the widget tree so its two
/// guarantees are testable without AR plumbing: a second completion signal
/// (or a restless Retry tap) never starts a second stitcher run, and the
/// review screen only opens on a result the service actually verified.
class StitchHandoff {
  StitchHandoff({
    required this.service,
    required this.total,
    required this.loadRecords,
    required this.onStarted,
    required this.onStage,
    required this.onSuccess,
    required this.onFailure,
  });

  final PanoramaGenerationService service;
  final int total;
  final Future<List<CaptureRecord>> Function() loadRecords;
  final VoidCallback onStarted;
  final void Function(String stage) onStage;
  final VoidCallback onSuccess;
  final void Function(String message) onFailure;

  bool _running = false;

  /// Whether a validation/stitch cycle is in flight.
  bool get running => _running;

  Future<void> complete() async {
    if (_running) return;
    _running = true;
    onStarted();
    try {
      final records = await loadRecords();
      final result = await service.generate(
        records: records,
        total: total,
        onStage: onStage,
      );
      _running = false;
      if (!result.success || result.panoramaPath == null) {
        onFailure(result.message);
        return;
      }
      onSuccess();
    } catch (error) {
      _running = false;
      onFailure('The panorama could not be generated: $error');
    }
  }
}

class _ArCaptureFlowScreenState extends State<ArCaptureFlowScreen> {
  CaptureRepository? _repository;
  String? _stationId;
  bool _preparing = true;

  /// The banner's running state mirrors [StitchHandoff.running]; the handoff
  /// itself owns the once-only guarantee.
  bool _stitching = false;

  /// The stage sentence while running, or the failure reason while stopped.
  String? _stage;

  StitchHandoff? _handoff;

  late final PanoramaStitcher _stitcher =
      widget.stitcher ?? OpenCvPanoramaStitcher();

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final repository =
        widget.repository ?? await FileCaptureRepository.create();
    if (!mounted) return;
    final stationId =
        widget.stationId ?? 'station-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _repository = repository;
      _stationId = stationId;
      _handoff = StitchHandoff(
        service: PanoramaGenerationService(_stitcher),
        total: buildCaptureSphere().length,
        loadRecords: () => repository.loadRecords(stationId),
        onStarted: () {
          if (mounted) {
            setState(() {
              _stitching = true;
              _stage = 'Validating frames...';
            });
          }
        },
        onStage: (String stage) {
          if (mounted) setState(() => _stage = stage);
        },
        onSuccess: () {
          if (!mounted) return;
          setState(() => _stitching = false);
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => CaptureReviewScreen(
                repository: repository,
                stationId: stationId,
                stitcher: _stitcher,
              ),
            ),
          );
        },
        onFailure: (String message) {
          if (mounted) {
            // The banner carries the reason and a Retry: the photographs are
            // still on disk, so nothing needs recapturing.
            setState(() {
              _stitching = false;
              _stage = message;
            });
          }
        },
      );
      _preparing = false;
    });
  }

  /// Called by [CaptureModuleScreen] when its controller reports every target
  /// saved. Validation runs against the records on disk — the screen's
  /// completion verdict is trusted for *when* to check, never *that* the 26
  /// files exist.
  void _onCaptureComplete() {
    _handoff?.complete();
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    final stationId = _stationId;
    if (_preparing || repository == null || stationId == null) {
      return const Scaffold(
        backgroundColor: CaptureColors.cameraChrome,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        CaptureModuleScreen(
          repository: repository,
          stationId: stationId,
          onComplete: _onCaptureComplete,
        ),
        if (_stitching || _stage != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _StitchingBanner(
              stage: _stage ?? 'Generating panorama...',
              running: _stitching,
              onRetry: _stitching ? null : _onCaptureComplete,
            ),
          ),
      ],
    );
  }
}

class _StitchingBanner extends StatelessWidget {
  const _StitchingBanner({
    required this.stage,
    required this.running,
    this.onRetry,
  });

  final String stage;
  final bool running;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.86),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        if (running) ...[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          const SizedBox(width: 12),
        ] else ...[
          const Icon(Icons.error_outline, color: CaptureColors.warn, size: 18),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            stage,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        if (!running && onRetry != null)
          TextButton(
            onPressed: onRetry,
            child: const Text(
              'Retry',
              style: TextStyle(color: CaptureColors.accent),
            ),
          ),
      ],
    ),
  );
}
