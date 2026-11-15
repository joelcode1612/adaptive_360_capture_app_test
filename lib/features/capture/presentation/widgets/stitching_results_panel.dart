import 'dart:io';

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/capture/data/stitch/incremental_stitch_service.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The Stitching Results section.
///
/// Two widgets, one truth: both read the live [IncrementalStitchService] the
/// host screen owns — never a second copy of its state.
///
/// * [StitchingResultsPanel] — the full section for the review screen and the
///   capture flow's detail sheet: per-image table, reasons, metrics, every
///   intermediate stitch ever produced, retry actions.
/// * [StitchingStatusStrip] — the compact overlay for the live capture
///   screen; tapping it opens the full panel. It never covers the reticle or
///   the guidance.
///
/// Nothing here can start a capture, move a target, or touch the camera —
/// the only actions are retry-verification (safe by construction) and
/// navigation.
class StitchingResultsPanel extends StatelessWidget {
  const StitchingResultsPanel({
    super.key,
    required this.service,
    required this.specs,
    this.onRetake,
    this.thumbnailFor,
    this.compact = false,
  });

  final IncrementalStitchService service;
  final List<CaptureTargetSpec> specs;

  /// Opens the existing retake flow (the review screen's own mechanism).
  final VoidCallback? onRetake;

  /// Absolute JPEG path for a target's *captured* frame, for row thumbnails.
  /// The stitch document deliberately stores no image paths, so the host
  /// (which reads the capture records) supplies them.
  final String? Function(int targetId)? thumbnailFor;

  /// Compact mode trims the preview cards for the bottom-sheet layout.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final doc = service.document;
    final savedIds =
        doc.records.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summaryHeader(doc),
        const SizedBox(height: 12),
        if (!compact) ...[
          _latestPreview(context, doc),
          const SizedBox(height: 12),
          _intermediateGallery(context, doc),
          const SizedBox(height: 12),
        ],
        if (doc.failCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => service.retryAllFailed(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry failed stitching'),
            ),
          ),
        _resultsTable(context, doc, savedIds),
      ],
    );
  }

  Widget _summaryHeader(StitchResultsDocument doc) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Stitching results',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
        if (doc.processingCount > 0 || service.busy)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        _countChip(
          '${doc.passCount} pass',
          foreground: Colors.white,
          background: Colors.green.withValues(alpha: 0.25),
        ),
        if (doc.failCount > 0)
          _countChip(
            '${doc.failCount} fail',
            foreground: Colors.white,
            background: CaptureColors.danger.withValues(alpha: 0.35),
          ),
        _countChip(
          '${doc.pendingCount} pending',
          foreground: Colors.white,
          background: Colors.white.withValues(alpha: 0.12),
        ),
      ],
    );
  }

  Widget _countChip(
    String label, {
    required Color foreground,
    required Color background,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: foreground, fontSize: 12),
    ),
  );

  /// The most recent output — final panorama when it exists, otherwise the
  /// newest intermediate — shown prominently.
  Widget _latestPreview(BuildContext context, StitchResultsDocument doc) {
    final path = doc.latestPreviewPath;
    if (path == null) {
      return Card(
        color: CaptureColors.sheet,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'The stitched preview appears here as soon as the first merge '
            'succeeds.',
            style: TextStyle(color: CaptureColors.mutedOnDark, fontSize: 12),
          ),
        ),
      );
    }
    final isFinal = path == doc.finalPanorama.panoramaPath;
    return Card(
      color: CaptureColors.sheet,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              isFinal
                  ? 'Final panorama'
                  : 'Latest stitched result '
                        '(targets ${_membersLabel(doc, path)})',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          SizedBox(
            height: 200,
            child: GestureDetector(
              onTap: () => _openPreview(context, path, isFinal: isFinal),
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(
                  child: Text(
                    'Output file unavailable.',
                    style: TextStyle(color: CaptureColors.mutedOnDark),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _membersLabel(StitchResultsDocument doc, String path) {
    for (final i in doc.intermediates) {
      if (i.path == path) return i.sourceTargetIds.join(', ');
    }
    return '?';
  }

  /// Every successfully produced intermediate, newest first.
  Widget _intermediateGallery(BuildContext context, StitchResultsDocument doc) {
    if (doc.intermediates.isEmpty) {
      return const SizedBox.shrink();
    }
    final items = doc.intermediates.reversed.toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Intermediate stitches (${items.length})',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              final item = items[index];
              return GestureDetector(
                onTap: () =>
                    _openPreview(context, item.path, isFinal: false),
                child: Container(
                  width: 150,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: CaptureColors.sheet,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(item.path),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.broken_image_outlined,
                          color: CaptureColors.mutedOnDark,
                        ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Targets ${item.sourceTargetIds.join(', ')}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _resultsTable(
    BuildContext context,
    StitchResultsDocument doc,
    List<int> savedIds,
  ) {
    return Card(
      color: CaptureColors.sheet,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final int id in savedIds)
            _resultRow(
              context,
              doc,
              doc.records[id]!,
              spec: _specFor(id),
            ),
        ],
      ),
    );
  }

  CaptureTargetSpec? _specFor(int id) {
    for (final spec in specs) {
      if (spec.targetId == id) return spec;
    }
    return null;
  }

  Widget _resultRow(
    BuildContext context,
    StitchResultsDocument doc,
    ImageStitchRecord record, {
    required CaptureTargetSpec? spec,
  }) {
    final label = spec == null
        ? 'Target ${record.targetId}'
        : 'Target ${record.targetId} · ${spec.ringName}'
              '${spec.indexInRing == null ? '' : ' ${spec.indexInRing}'}';
    final thumbnailPath =
        thumbnailFor?.call(record.targetId) ?? record.stitchedOutputPath;
    return InkWell(
      onTap: () => _openDetail(context, record),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52,
                height: 40,
                child: ColoredBox(
                  color: Colors.black26,
                  child:
                      thumbnailPath == null || thumbnailPath.isEmpty
                      ? const Icon(
                          Icons.image_outlined,
                          color: CaptureColors.mutedOnDark,
                          size: 18,
                        )
                      : Image.file(
                          File(thumbnailPath),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.image_outlined,
                            color: CaptureColors.mutedOnDark,
                            size: 18,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (record.stitchStatus == StitchStatus.fail &&
                      record.errorReason != null)
                    Text(
                      record.errorReason!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CaptureColors.warn,
                        fontSize: 11,
                      ),
                    )
                  else if (record.stitchStatus == StitchStatus.pass &&
                      record.mergeError != null)
                    Text(
                      record.mergeError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CaptureColors.mutedOnDark,
                        fontSize: 11,
                      ),
                    )
                  else if (record.stitchStatus == StitchStatus.pending &&
                      record.errorReason != null)
                    Text(
                      record.errorReason!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CaptureColors.mutedOnDark,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _captureChip(),
            const SizedBox(width: 6),
            _stitchChip(record.stitchStatus),
            if (record.stitchStatus == StitchStatus.fail)
              IconButton(
                tooltip: 'Retry stitching',
                onPressed: () => service.retryTarget(record.targetId),
                icon: const Icon(Icons.refresh, size: 20),
                color: Colors.white,
              ),
          ],
        ),
      ),
    );
  }

  Widget _captureChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.green.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(999),
    ),
    child: const Text(
      'Saved',
      style: TextStyle(color: Colors.white, fontSize: 10.5),
    ),
  );

  Widget _stitchChip(StitchStatus status) {
    final (Color bg, Color fg) = switch (status) {
      StitchStatus.pass => (
        Colors.green.withValues(alpha: 0.35),
        Colors.white,
      ),
      StitchStatus.fail => (CaptureColors.danger.withValues(alpha: 0.5), Colors.white),
      StitchStatus.processing => (
        CaptureColors.accent.withValues(alpha: 0.5),
        Colors.white,
      ),
      StitchStatus.pending => (
        Colors.white.withValues(alpha: 0.14),
        CaptureColors.mutedOnDark,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(color: fg, fontSize: 10.5),
      ),
    );
  }

  void _openPreview(
    BuildContext context,
    String path, {
    required bool isFinal,
  }) {
    showDialog<void>(
      barrierColor: Colors.black87,
      context: context,
      builder: (BuildContext context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 24,
              left: 12,
              child: Text(
                isFinal ? 'Final panorama' : 'Intermediate stitch',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            Positioned(
              top: 16,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, ImageStitchRecord record) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: CaptureColors.sheet,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Target ${record.targetId} — stitching detail',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _metricRow(
                'Capture',
                record.captureStatus == 'saved' ? 'Saved' : record.captureStatus,
              ),
              _metricRow('Stitching', record.stitchStatus.label),
              if (record.matchedTargetIds.isNotEmpty)
                _metricRow(
                  'Matched neighbours',
                  record.matchedTargetIds.join(', '),
                ),
              if (record.featureMatches != null)
                _metricRow('Good matches', '${record.featureMatches}'),
              if (record.inliers != null)
                _metricRow('Inliers (RANSAC)', '${record.inliers}'),
              if (record.inlierRatio != null)
                _metricRow(
                  'Inlier ratio',
                  '${(record.inlierRatio! * 100).toStringAsFixed(0)}%',
                ),
              if (record.registrationErrorPx != null)
                _metricRow(
                  'Reprojection error',
                  '${record.registrationErrorPx!.toStringAsFixed(2)} px',
                ),
              if (record.overlapFraction != null)
                _metricRow(
                  'Measured overlap',
                  '${(record.overlapFraction! * 100).toStringAsFixed(0)}%',
                ),
              if (record.laplacianVariance != null)
                _metricRow(
                  'Detail (Laplacian var.)',
                  record.laplacianVariance!.toStringAsFixed(1),
                ),
              if (record.brightness != null)
                _metricRow(
                  'Brightness',
                  '${record.brightness!.toStringAsFixed(0)}/255',
                ),
              if (record.stitcherStatus != null)
                _metricRow('Stitcher status', record.stitcherStatus!),
              if (record.errorReason != null)
                _metricRow('Reason', record.errorReason!),
              if (record.mergeError != null)
                _metricRow('Merge note', record.mergeError!),
              _metricRow('Attempts', '${record.attempts}'),
              if (record.stitchedOutputPath != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 140,
                      width: double.infinity,
                      child: Image.file(
                        File(record.stitchedOutputPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (record.stitchStatus == StitchStatus.fail ||
                      record.stitchStatus == StitchStatus.pass)
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        service.retryTarget(record.targetId);
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry stitching'),
                    ),
                  if (onRetake != null &&
                      (record.stitchStatus == StitchStatus.fail)) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        onRetake!();
                      },
                      icon: const Icon(Icons.replay_rounded, size: 18),
                      label: const Text('Retake photo'),
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

  Widget _metricRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: const TextStyle(color: CaptureColors.mutedOnDark, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

/// The compact live strip for the capture screen: one line, tap to expand.
class StitchingStatusStrip extends StatelessWidget {
  const StitchingStatusStrip({super.key, required this.service});

  final IncrementalStitchService service;

  @override
  Widget build(BuildContext context) {
    final doc = service.document;
    if (doc.records.isEmpty) return const SizedBox.shrink();
    final parts = <String>[
      if (doc.passCount > 0) '${doc.passCount} stitched',
      if (doc.failCount > 0) '${doc.failCount} failed',
      if (doc.pendingCount > 0) '${doc.pendingCount} pending',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          showModalBottomSheet<void>(
            context: context,
            backgroundColor: CaptureColors.cameraChrome,
            isScrollControlled: true,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            builder: (BuildContext sheetContext) => SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: StitchingResultsPanel(
                  service: service,
                  specs: buildCaptureSphere(),
                ),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (service.busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(
                  Icons.auto_awesome_motion_outlined,
                  size: 14,
                  color: Colors.white70,
                ),
              const SizedBox(width: 8),
              Text(
                'Stitching: ${parts.join(' · ')}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_less, size: 16, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
