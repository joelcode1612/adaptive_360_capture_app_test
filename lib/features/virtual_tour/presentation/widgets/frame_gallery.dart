import 'dart:io';
import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/data/station_group.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/widgets/flow_widgets.dart';

/// One cell of the review gallery.
///
/// Built by the review screen from the station record plus the paths the store
/// uses, so the widget itself never has to know what a session repository is.
class GalleryFrame {
  final int index;

  /// The prototype's name for the view, e.g. "Middle ring · 3 of 8".
  final String title;
  final TargetStatus status;

  /// Where the photograph of this frame should be. `null` for a frame the
  /// station never accepted.
  final String? imagePath;

  /// Set when the review asked for this exact view again.
  final bool needsRetake;

  const GalleryFrame({
    required this.index,
    required this.title,
    required this.status,
    this.imagePath,
    this.needsRetake = false,
  });

  bool get hasSlot => imagePath != null;
}

/// The photographs this station actually has, as thumbnails.
///
/// This is the review screen's "preview area" — the prototype draws a simulated
/// panorama strip there, and this replaces it with the real files. Every tile is
/// an `Image.file` of the JPEG the camera took, decoded when it scrolls into
/// view, so a green tile means *this picture exists and could be opened*.
///
/// A tile whose file is missing or unreadable is drawn as a broken frame rather
/// than silently dropped: an accepted frame that cannot be read is the one thing
/// a reviewer must not be able to miss.
class FrameGallery extends StatelessWidget {
  const FrameGallery({super.key, required this.frames, this.onOpen});

  final List<GalleryFrame> frames;
  final void Function(GalleryFrame frame)? onOpen;

  static const double _maxTileExtent = 120;
  static const double _tileAspect = 1.15;

  @override
  Widget build(BuildContext context) {
    final stored = frames.where((f) => f.hasSlot).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Photographs',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$stored of ${frames.length} on disk',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).brightness == Brightness.light
                    ? SiteWiseColors.muted
                    : CaptureColors.mutedOnDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / _maxTileExtent)
                .ceil()
                .clamp(2, 8);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: _tileAspect,
              ),
              itemCount: frames.length,
              itemBuilder: (context, i) => _FrameTile(
                frame: frames[i],
                onTap: onOpen == null ? null : () => onOpen!(frames[i]),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _FrameTile extends StatelessWidget {
  const _FrameTile({required this.frame, this.onTap});

  final GalleryFrame frame;
  final VoidCallback? onTap;

  Color _ring(bool light) => switch (frame.status) {
    TargetStatus.ok =>
      frame.needsRetake
          ? (light ? CaptureColors.warnOnLight : CaptureColors.warn)
          : (light ? CaptureColors.okOnLight : CaptureColors.ok),
    TargetStatus.skipped =>
      light ? CaptureColors.warnOnLight : CaptureColors.warn,
    TargetStatus.pending => Colors.transparent,
  };

  @override
  Widget build(BuildContext context) {
    final path = frame.imagePath;
    final light = Theme.of(context).brightness == Brightness.light;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
          border: Border.all(
            color: frame.status == TargetStatus.pending
                ? (light ? SiteWiseColors.border : CaptureColors.hairlineOnDark)
                : _ring(light),
            width: 2,
          ),
          color: light ? SiteWiseColors.paper : CaptureColors.cardOnDark,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path == null)
              Center(
                child: Icon(
                  Icons.photo_camera_outlined,
                  size: 20,
                  color: light
                      ? CaptureColors.pendingDotOnLight
                      : CaptureColors.mutedOnDark,
                ),
              )
            else
              Image.file(
                File(path),
                fit: BoxFit.cover,
                // Decode at thumbnail width: a station is 26 full-size
                // photographs, and decoding them all at 4000×3000 is how a
                // review screen gets killed on a mid-range phone.
                cacheWidth: 240,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => const _BrokenThumb(),
              ),
            Positioned(
              left: 4,
              bottom: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CaptureColors.chromeOverlay(),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  child: Text(
                    '${frame.index + 1}',
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            if (frame.needsRetake)
              const Positioned(
                right: 3,
                top: 3,
                child: Icon(Icons.refresh, size: 15, color: CaptureColors.warn),
              ),
          ],
        ),
      ),
    );
  }
}

/// A tile whose file is named by the manifest but did not decode.
///
/// The alternative — a grey rectangle — would read as "not captured yet", which
/// is a different problem with a different fix.
class _BrokenThumb extends StatelessWidget {
  const _BrokenThumb();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: CaptureColors.warn.withValues(alpha: 0.18),
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: CaptureColors.warn,
          ),
          SizedBox(height: 2),
          Text(
            'cannot open',
            style: TextStyle(fontSize: 9, color: CaptureColors.warn),
          ),
        ],
      ),
    ),
  );
}

/// The full-size view of one captured photograph and the evidence stored with it.
///
/// Everything here is read back from disk by [loader] when the page opens, so
/// the numbers describe the file the user is looking at. Fields the evidence file
/// does not carry are shown as "not recorded" rather than estimated.
class FramePreviewPage extends StatelessWidget {
  const FramePreviewPage({
    super.key,
    required this.title,
    required this.loader,
  });

  final String title;
  final Future<FrameEvidence> Function() loader;

  @override
  Widget build(BuildContext context) {
    // The same header the nine screens use. An `AppBar` here would be the only
    // tinted bar left in the app, and this page is reached from the review, so
    // it should look like the rest of it.
    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      body: SafeArea(
        child: Column(
          children: [
            FlowHeader(
              title: title,
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: FutureBuilder<FrameEvidence>(
                future: loader(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(color: CaptureColors.ok),
                    );
                  }
                  final evidence = snapshot.data;
                  if (evidence == null) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text('This frame could not be read.'),
                      ),
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                    children: [
                      _Photo(evidence: evidence),
                      const SizedBox(height: 14),
                      _Verdict(evidence: evidence),
                      const SizedBox(height: 14),
                      _Rows(evidence: evidence),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.evidence});

  final FrameEvidence evidence;

  @override
  Widget build(BuildContext context) {
    if (!evidence.integrity.isStored) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: CaptureColors.warn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
          border: Border.all(color: CaptureColors.warn),
        ),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'There is no readable photograph here to show.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: CaptureColors.cameraChrome,
        borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(
            File(evidence.imagePath),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const Center(
              child: Text(
                'The file is there but Flutter could not decode it.',
                style: TextStyle(color: CaptureColors.mutedOnDark),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.evidence});

  final FrameEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final color = evidence.complete
        ? (evidence.meta?.warning == null
              ? CaptureColors.ok
              : CaptureColors.warn)
        : CaptureColors.danger;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
        border: Border.all(color: color),
      ),
      child: Row(
        children: [
          Icon(
            evidence.complete
                ? (evidence.meta?.warning == null
                      ? Icons.check_circle_outline
                      : Icons.warning_amber)
                : Icons.error_outline,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(evidence.verdict)),
        ],
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({required this.evidence});

  final FrameEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final m = evidence.meta;
    final integrity = evidence.integrity;
    final stats = m?.stats;
    final pose = m?.pose;
    return Container(
      decoration: BoxDecoration(
        color: CaptureColors.groupOnDark,
        borderRadius: BorderRadius.circular(CaptureMetrics.smallRadius),
        border: Border.all(color: CaptureColors.hairlineOnDark),
      ),
      child: Column(
        children: [
          _row('File', _basename(evidence.imagePath)),
          _row('Read back', integrity.label),
          _row('Image size', integrity.dimensionsLabel),
          _row(
            'Saved on this device',
            m?.savedAt == null ? 'not recorded' : _localTime(m!.savedAt!),
          ),
          if (m != null) ...[
            _row(
              'Camera field of view',
              '${_deg(m.hfovDeg)} × ${_deg(m.vfovDeg)}',
            ),
            _row(
              'Aim error when taken',
              m.errorDeg == null ? 'not measured' : _deg(m.errorDeg!),
            ),
            _row('Attempts', '${m.attempts}'),
            _row('Shot', m.manual ? 'manual — aim not verified' : 'automatic'),
            if (m.shifted)
              _row('Station', 'the phone had moved within tolerance'),
            if (m.lost) _row('At capture', 'the file was reported lost'),
            _row(
              'Pose',
              pose == null
                  ? 'no pose recorded'
                  : 'quaternion ${_f4(pose.w)}, ${_f4(pose.x)}, '
                        '${_f4(pose.y)}, ${_f4(pose.z)}',
            ),
          ],
          if (stats != null) ...[
            _row('Mean brightness', _f3(stats.mean)),
            _row('Dark area share', _pct(stats.darkShare)),
            _row('Blown-out share', _pct(stats.saturatedShare)),
            _row('Sharpness (edge energy)', _f2(stats.laplacianVariance)),
            _row('Texture (gradient mean)', _f2(stats.gradientMean)),
            _row('Strong edges', _pct(stats.strongEdgeShare)),
            _row('Detail (entropy)', _f2(stats.entropy)),
          ],
          _row(
            'Direction',
            'target yaw ${m == null ? '—' : _deg(m.targetYawDeg)}, '
                'pitch ${m == null ? '—' : _deg(m.targetPitchDeg)}',
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Container(
    // `.sl>div` — hairline-separated label/value rows.
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: CaptureColors.hairlineFaint)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 148,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: CaptureColors.mutedOnDark,
            ),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );
}

String _basename(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

String _deg(double v) => '${v.toStringAsFixed(1)}°';

String _f2(double v) => v.toStringAsFixed(2);

String _f3(double v) => v.toStringAsFixed(3);

String _f4(double v) => v.toStringAsFixed(4);

String _pct(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';

String _localTime(DateTime t) {
  final local = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Opens [FramePreviewPage] for one frame.
Future<void> openFramePreview(
  BuildContext context, {
  required String title,
  required Future<FrameEvidence> Function() evidence,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FramePreviewPage(title: title, loader: evidence),
  ),
);
