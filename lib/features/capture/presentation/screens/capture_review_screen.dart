import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/application/panorama_generation_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/screens/ar_capture_flow_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Local photograph review and 360° preview for one finished capture station.
///
/// Everything shown is read back from the station directory: the records are
/// the evidence a photograph exists, `panorama.json` is the evidence a
/// panorama was generated, and the JPEGs themselves are the only images ever
/// rendered. Nothing here deletes an accepted photograph — a retry re-stitches
/// from disk and a retake reopens the capture screen for the same station,
/// where the controller's resume/recalibrate paths own the recovery.
class CaptureReviewScreen extends StatefulWidget {
  const CaptureReviewScreen({
    super.key,
    required this.repository,
    required this.stationId,
    required this.stitcher,
  });

  final CaptureRepository repository;
  final String stationId;
  final PanoramaStitcher stitcher;

  @override
  State<CaptureReviewScreen> createState() => _CaptureReviewScreenState();
}

class _CaptureReviewScreenState extends State<CaptureReviewScreen> {
  final _specs = buildCaptureSphere();

  List<CaptureRecord> _records = const <CaptureRecord>[];

  /// The panorama metadata sidecar, `null` while nothing was generated yet.
  Map<String, dynamic>? _panorama;

  bool _loading = true;
  bool _generating = false;
  String? _stage;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final records = await widget.repository.loadRecords(widget.stationId);
    Map<String, dynamic>? panorama;
    final framesDirectory = _framesDirectory(records);
    if (framesDirectory != null) {
      final meta = File(p.join(p.dirname(framesDirectory), 'panorama.json'));
      if (await meta.exists()) {
        try {
          panorama =
              jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          panorama = null;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _records = records;
      _panorama = panorama;
      _loading = false;
    });
  }

  /// The panorama (and its sidecar) live beside `frames/`. The directory is
  /// recovered from a saved frame path rather than from a layout convention
  /// this screen would have to re-implement; a station without records has no
  /// panorama to find.
  String? _framesDirectory(List<CaptureRecord> records) {
    for (final CaptureRecord record in records) {
      final frames = p.dirname(record.imagePath);
      if (p.basename(frames) == 'frames') return frames;
    }
    return null;
  }

  Set<int> _savedIds() => <int>{
    for (final CaptureRecord record in _records)
      if (record.targetId >= 1 && record.targetId <= _specs.length)
        record.targetId,
  };

  List<int> _missingIds() {
    final saved = _savedIds();
    return <int>[
      for (final spec in _specs)
        if (!saved.contains(spec.targetId)) spec.targetId,
    ];
  }

  String _labelFor(CaptureTargetSpec spec) => spec.isZenith
      ? 'Zenith'
      : spec.isNadir
      ? 'Nadir'
      : '${spec.ringName} ${spec.indexInRing}';

  /// Re-runs validation and stitching against what is on disk now. A retake
  /// between attempts is picked up automatically; nothing is ever deleted.
  Future<void> _retryStitching() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _stage = 'Validating frames...';
      _error = null;
    });
    try {
      final records = await widget.repository.loadRecords(widget.stationId);
      final result = await PanoramaGenerationService(widget.stitcher).generate(
        records: records,
        total: _specs.length,
        onStage: (String stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (!mounted) return;
      if (!result.success || result.panoramaPath == null) {
        setState(() {
          _generating = false;
          _stage = null;
          _error = result.message;
        });
        return;
      }
      setState(() {
        _generating = false;
        _stage = null;
      });
      await _reload();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = null;
        _error = 'The panorama could not be generated: $error';
      });
    }
  }

  void _retake() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ArCaptureFlowScreen(
          repository: widget.repository,
          stationId: widget.stationId,
          stitcher: widget.stitcher,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: CaptureColors.cameraChrome,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final missing = _missingIds();
    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      appBar: AppBar(
        backgroundColor: CaptureColors.cameraChrome,
        foregroundColor: Colors.white,
        title: const Text('Capture review'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _completenessCard(missing),
          const SizedBox(height: 12),
          _panoramaSection(),
          const SizedBox(height: 12),
          if (_generating)
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _stage ?? 'Processing...',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: CaptureColors.danger),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _generating ? null : _retryStitching,
            icon: const Icon(Icons.auto_awesome),
            label: Text(
              _panorama == null ? 'Retry stitching' : 'Regenerate panorama',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: CaptureColors.accent,
              side: const BorderSide(color: CaptureColors.accent),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _generating ? null : _retake,
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Retake photographs'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: CaptureColors.hairlineOnDark),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Photographs (${_records.length}/${_specs.length})',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          _frameGrid(missing),
        ],
      ),
    );
  }

  Widget _completenessCard(List<int> missing) {
    final complete = missing.isEmpty;
    return Card(
      color: CaptureColors.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CaptureMetrics.cornerRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              complete
                  ? 'All ${_specs.length} photographs saved.'
                  : '${_records.length} of ${_specs.length} photographs saved.',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              complete
                  ? 'The panorama below is stitched from these saved frames.'
                  : 'Missing targets: ${missing.take(10).join(', ')}'
                        '${missing.length > 10 ? ' (+${missing.length - 10} more)' : ''}. '
                        'Retake to capture the rest — saved frames are kept.',
              style: TextStyle(
                color: complete
                    ? CaptureColors.mutedOnDark
                    : CaptureColors.warn,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panoramaSection() {
    final path = _panorama?['panoramaPath'] as String?;
    if (path == null) {
      return Card(
        color: CaptureColors.sheet,
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Generate the panorama to preview it here.',
            style: TextStyle(color: CaptureColors.mutedOnDark),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(CaptureMetrics.cornerRadius),
      child: SizedBox(
        height: 300,
        child: PanoramaViewer(
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const Center(
              child: Text(
                'Panorama file unavailable. Try regenerating it.',
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _frameGrid(List<int> missing) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: _specs.length,
      itemBuilder: (BuildContext context, int index) {
        final spec = _specs[index];
        final record = _recordFor(spec.targetId);
        final isMissing = missing.contains(spec.targetId);
        return Card(
          color: CaptureColors.sheet,
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: record == null
                    ? Icon(
                        Icons.image_not_supported_outlined,
                        color: CaptureColors.warn,
                      )
                    : Image.file(
                        File(record.imagePath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.image_not_supported_outlined,
                          color: CaptureColors.danger,
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  '${spec.targetId} · ${_labelFor(spec)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isMissing
                        ? CaptureColors.warn
                        : CaptureColors.headerMuted,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  CaptureRecord? _recordFor(int targetId) {
    for (final CaptureRecord record in _records) {
      if (record.targetId == targetId) return record;
    }
    return null;
  }
}
