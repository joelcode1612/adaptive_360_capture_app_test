import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';

/// Panorama generation orchestration for the 26-target AR capture: validates
/// the saved-record set, delegates stitching to the injected [PanoramaStitcher]
/// and records the output path beside the panorama so the review screen never
/// has to guess where the stitcher wrote.
///
/// Stateless by design: a retry re-runs the whole validation and stitch cycle
/// against whatever is on disk now, and no path here deletes a photograph.
class PanoramaGenerationService {
  final PanoramaStitcher stitcher;

  const PanoramaGenerationService(this.stitcher);

  Future<StitchResult> generate({
    required List<CaptureRecord> records,
    required int total,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('Validating frames...');

    // Capture order is the stitch order: target ids 1…total, the sphere
    // sequence the shutter advanced through.
    final ordered = List<CaptureRecord>.of(records)
      ..sort(
        (CaptureRecord a, CaptureRecord b) => a.targetId.compareTo(b.targetId),
      );
    final seenIds = <int>{};
    for (final CaptureRecord record in ordered) {
      if (record.targetId < 1 || record.targetId > total) {
        return StitchResult.failure(
          'Capture record ${record.targetId} is outside the 1–$total '
          'target range.',
        );
      }
      if (!seenIds.add(record.targetId)) {
        return StitchResult.failure(
          'Duplicate capture record for target ${record.targetId}.',
        );
      }
    }
    if (ordered.length < total) {
      final missing = <int>[
        for (var id = 1; id <= total; id++)
          if (!seenIds.contains(id)) id,
      ];
      final named = missing.take(6).join(', ');
      final more = missing.length > 6 ? ' (+${missing.length - 6} more)' : '';
      return StitchResult.failure(
        'Panorama cannot be generated. Only ${ordered.length}/$total '
        'photographs are saved. Missing targets: $named$more.',
      );
    }
    final paths = <String>[];
    for (final CaptureRecord record in ordered) {
      if (!await File(record.imagePath).exists()) {
        return StitchResult.failure(
          'The saved photograph for target ${record.targetId} is missing on '
          'disk (${record.imagePath}). Retake this target and try again.',
        );
      }
      paths.add(record.imagePath);
    }
    if (paths.toSet().length != paths.length) {
      return const StitchResult.failure(
        'Two capture records point at one image file, so the frame set is '
        'not usable.',
      );
    }

    onStage?.call('Generating panorama...');
    final StitchResult result = await stitcher.stitchFrames(
      paths,
      onStage: onStage,
    );
    if (!result.success || result.panoramaPath == null) {
      return result;
    }

    try {
      final meta = File(
        p.join(p.dirname(result.panoramaPath!), 'panorama.json'),
      );
      await meta.writeAsString(
        jsonEncode(<String, Object?>{
          'stationId': ordered.first.stationId,
          'panoramaPath': result.panoramaPath,
          'frameCount': paths.length,
          'generatedAt': DateTime.now().toIso8601String(),
          'message': result.message,
        }),
        flush: true,
      );
    } catch (error) {
      // The panorama file itself is intact on disk; reporting failure instead
      // of success keeps the app from advertising a preview it cannot resolve
      // again after a restart.
      return StitchResult.failure(
        'Panorama rendered but its output path could not be recorded: $error',
      );
    }
    return result;
  }
}
