import 'dart:io';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/application/panorama_sync_service.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// The property-detail side of the panorama workflow.
///
/// A property screen has four things to say, and saying the wrong one is a
/// product bug rather than a cosmetic one:
///
/// * **not captured** — nothing to show, and nothing to apologise for;
/// * **processing** — the panorama exists but is not `done` in the cloud yet, so
///   showing it would publish an unfinished capture;
/// * **failed** — say why, and offer the retry rather than a dead end;
/// * **ready** — open the existing 360° viewer, using the on-device file when
///   this is the device that captured it and a short-lived signed URL otherwise.
///
/// A signed URL is minted when this widget is built and never stored, so a
/// screenshot of the network log is not a permanent key to a private object.
class PropertyPanoramaView extends StatelessWidget {
  const PropertyPanoramaView({
    super.key,
    required this.view,
    this.onRetry,
    this.onRefresh,
  });

  final PanoramaView view;

  /// Offered only for [PanoramaViewState.failed].
  final VoidCallback? onRetry;

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SiteWiseColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SiteWiseColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.threesixty,
              size: 18,
              color: view.state == PanoramaViewState.ready
                  ? SiteWiseColors.primary
                  : SiteWiseColors.muted,
            ),
            const SizedBox(width: 8),
            Text(
              '360° panorama',
              style: const TextStyle(
                color: SiteWiseColors.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _Body(view: view),
        if (view.state == PanoramaViewState.failed && onRetry != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry upload'),
          ),
        ],
        if (onRefresh != null) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: onRefresh,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, CaptureMetrics.minTouchTarget),
            ),
            child: const Text('Check again'),
          ),
        ],
      ],
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.view});

  final PanoramaView view;

  @override
  Widget build(BuildContext context) {
    switch (view.state) {
      case PanoramaViewState.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Published and ready to explore.',
              style: TextStyle(
                color: SiteWiseColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SitewisePanoramaScreen(view: view),
                ),
              ),
              icon: const Icon(Icons.open_in_full, size: 16),
              label: const Text('Open 360° viewer'),
              style: FilledButton.styleFrom(
                backgroundColor: SiteWiseColors.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      case PanoramaViewState.processing:
        return Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                view.message ?? 'Preparing the panorama…',
                style: const TextStyle(
                  color: SiteWiseColors.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        );
      case PanoramaViewState.failed:
        return Text(
          view.message ?? 'The panorama is not available.',
          style: const TextStyle(
            color: CaptureColors.dangerOnLight,
            fontSize: 12,
            height: 1.45,
          ),
        );
      case PanoramaViewState.notCaptured:
        return Text(
          view.message ?? 'No panorama has been captured for this property yet.',
          style: const TextStyle(
            color: SiteWiseColors.muted,
            fontSize: 12,
            height: 1.45,
          ),
        );
    }
  }
}

/// Opens a panorama from either a local file or a signed URL.
///
/// The local file wins when both exist: it needs no network, and it is the
/// bytes this device actually stitched.
class SitewisePanoramaScreen extends StatelessWidget {
  const SitewisePanoramaScreen({super.key, required this.view});

  final PanoramaView view;

  @override
  Widget build(BuildContext context) {
    final localPath = view.localPath;
    final url = view.signedUrl;
    final Image image;
    if (localPath != null && File(localPath).existsSync()) {
      image = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const _ViewerError(
          'The local panorama could not be decoded.',
        ),
      );
    } else if (url != null) {
      image = Image.network(
        url,
        fit: BoxFit.cover,
        loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? progress) =>
            progress == null
            ? child
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => const _ViewerError(
          'The panorama could not be downloaded. The link may have expired.',
        ),
      );
    } else {
      return const Scaffold(
        backgroundColor: CaptureColors.cameraChrome,
        body: _ViewerError('There is no panorama to show.'),
      );
    }

    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      appBar: AppBar(
        backgroundColor: CaptureColors.cameraChrome,
        foregroundColor: Colors.white,
        title: const Text('360° Panorama'),
      ),
      body: PanoramaViewer(
        sensorControl: SensorControl.orientation,
        child: image,
      ),
    );
  }
}

class _ViewerError extends StatelessWidget {
  const _ViewerError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: CaptureColors.mutedOnDark, height: 1.5),
      ),
    ),
  );
}
