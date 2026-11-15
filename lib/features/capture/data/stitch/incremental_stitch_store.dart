import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/stitch/incremental_stitch_models.dart';

/// Filesystem persistence for the incremental stitch results of one station.
///
/// Layout, inside the station directory the capture repository already owns:
///
/// ```
/// <station>/
///   frames/tNN.jpg            (unchanged — the originals)
///   panorama.jpg, panorama.json   (unchanged — the final stitch)
///   stitch_results/
///     stitching_results.json  per-image records, group, final status
///   stitched_outputs/
///     stitch_001.jpg …        intermediates, one per successful merge
/// ```
///
/// Writes are atomic in the practical sense: the JSON is written to a temp
/// file and renamed, so a kill mid-write leaves the previous complete
/// document on disk rather than a truncated one.
class IncrementalStitchStore {
  final String stationDir;

  IncrementalStitchStore(this.stationDir);

  String get resultsDir => p.join(stationDir, 'stitch_results');
  String get outputsDir => p.join(stationDir, 'stitched_outputs');
  String get resultsFile => p.join(resultsDir, 'stitching_results.json');

  Future<StitchResultsDocument?> load() async {
    final file = File(resultsFile);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return StitchResultsDocument.fromJson(json);
    } catch (_) {
      // A corrupt document is treated as absent: the records rebuild from
      // fresh worker runs, and the original JPEGs are never touched.
      return null;
    }
  }

  Future<void> save(StitchResultsDocument document) async {
    final dir = Directory(resultsDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    // A unique temp name: two writers (a job finishing while the controller
    // signals a new capture) must never contend for one pending file.
    final temp = File(
      p.join(
        resultsDir,
        '.stitching_results.${DateTime.now().microsecondsSinceEpoch}.pending',
      ),
    );
    await temp.writeAsString(jsonEncode(document.toJson()), flush: true);
    // Windows can refuse the rename while another handle still holds the
    // target; a short retry covers that without losing either version.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await temp.rename(resultsFile);
        return;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    try {
      await temp.delete();
    } catch (_) {}
    // Re-throwing keeps the caller's "persistence failed" path honest; the
    // in-memory document and the next save still carry the state.
    throw lastError ?? StateError('rename failed');
  }

  /// Next intermediate output path: `stitch_NNN.jpg`, continuing the highest
  /// existing index so retries never overwrite a previous output.
  Future<String> nextOutputPath() async {
    final dir = Directory(outputsDir);
    var highest = 0;
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        final match = RegExp(r'^stitch_(\d{3})\.jpg$').firstMatch(name);
        if (match != null) {
          final n = int.parse(match.group(1)!);
          if (n > highest) highest = n;
        }
      }
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return p.join(outputsDir, 'stitch_${(highest + 1).toString().padLeft(3, '0')}.jpg');
  }

  /// Every intermediate output that still exists on disk, oldest first.
  Future<List<String>> existingOutputs() async {
    final dir = Directory(outputsDir);
    if (!await dir.exists()) return const <String>[];
    final files = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File &&
          RegExp(r'^stitch_\d{3}\.jpg$').hasMatch(p.basename(entity.path))) {
        files.add(entity.path);
      }
    }
    files.sort();
    return files;
  }
}
