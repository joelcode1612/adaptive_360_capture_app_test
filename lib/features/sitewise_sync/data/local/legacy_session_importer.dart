// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/capture_session_store.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

/// What a legacy import did, so the caller can log it rather than guess.
class LegacyImportReport {
  const LegacyImportReport({
    required this.stationsScanned,
    required this.sessionsImported,
    required this.framesImported,
    required this.panoramasImported,
    required this.skipped,
  });

  final int stationsScanned;
  final int sessionsImported;
  final int framesImported;
  final int panoramasImported;

  /// Human-readable reasons a station was not imported. Never a silent skip.
  final List<String> skipped;

  bool get didAnything => sessionsImported > 0 || framesImported > 0;

  @override
  String toString() =>
      'LegacyImportReport(stations: $stationsScanned, sessions: '
      '$sessionsImported, frames: $framesImported, panoramas: '
      '$panoramasImported, skipped: ${skipped.length})';
}

/// Imports the JSON station directories written before SQLite existed.
///
/// ## Why this is not a destructive migration
///
/// The pre-SQLite app kept everything in `ar_capture/<stationId>/`:
/// `station.json`, `records.json`, `frames/t01.jpg …` and, once stitched,
/// `panorama.jpg` + `panorama.json`. That data is the user's photographs. This
/// importer **reads** it and writes rows; it deletes nothing, rewrites nothing
/// and never moves a JPEG. If it fails halfway, the JSON files are still the
/// complete record and the next launch retries.
///
/// ## Idempotency
///
/// A station whose session id already exists in SQLite is skipped, so running
/// this on every launch is cheap and cannot duplicate frames. A session that was
/// partially imported is completed rather than restarted, because
/// [CaptureSessionStore.saveFrame] replaces by `(session_id, target_id)`.
class LegacySessionImporter {
  LegacySessionImporter({
    required CaptureRepository repository,
    required CaptureSessionStore store,
  }) : _repository = repository,
       _store = store;

  final CaptureRepository _repository;
  final CaptureSessionStore _store;

  /// Imports every station that is not already represented in SQLite.
  Future<LegacyImportReport> importAll() async {
    final List<String> stationIds;
    try {
      stationIds = await _repository.stationIds();
    } catch (error) {
      return LegacyImportReport(
        stationsScanned: 0,
        sessionsImported: 0,
        framesImported: 0,
        panoramasImported: 0,
        skipped: <String>['The station directory could not be read: $error'],
      );
    }

    var sessions = 0;
    var frames = 0;
    var panoramas = 0;
    final skipped = <String>[];

    for (final stationId in stationIds) {
      final existing = await _store.getSession(stationId);
      if (existing != null && existing.status != CaptureSessionStatus.draft) {
        skipped.add('$stationId: already present in SQLite');
        continue;
      }
      try {
        final result = await _importStation(stationId);
        if (result == null) {
          skipped.add('$stationId: no capture records to import');
          continue;
        }
        sessions++;
        frames += result.frames;
        if (result.panorama != null) panoramas++;
      } catch (error) {
        skipped.add('$stationId: $error');
      }
    }

    final report = LegacyImportReport(
      stationsScanned: stationIds.length,
      sessionsImported: sessions,
      framesImported: frames,
      panoramasImported: panoramas,
      skipped: skipped,
    );
    debugPrint('SITEWISE_IMPORT: $report');
    for (final reason in skipped) {
      debugPrint('SITEWISE_IMPORT: skipped $reason');
    }
    return report;
  }

  Future<({int frames, String? panorama})?> _importStation(String stationId) async {
    final records = await _repository.loadRecords(stationId);
    if (records.isEmpty) return null;

    // The station's declared target count is the authority for how many
    // photographs a complete capture has; falling back to 38 keeps a legacy
    // 3DoF station (which never wrote `station.json`) importable.
    int required = kSphereTargetCount;
    try {
      final station = await _repository.loadStation(stationId);
      if (station != null && station.total > 0) required = station.total;
    } catch (error) {
      debugPrint('SITEWISE_IMPORT: $stationId has no readable station.json: $error');
    }
    if (records.length > required) required = records.length;

    await _store.createSession(
      sessionId: stationId,
      requiredTargetCount: required,
    );

    var imported = 0;
    for (final CaptureRecord record in records) {
      // A record whose JPEG has gone is not evidence. Importing it would make
      // the app claim 38 targets while the stitcher finds 37 files.
      if (!await File(record.imagePath).exists()) continue;
      await _store.saveFrame(CapturedFrame.fromCaptureRecord(record));
      imported++;
    }
    if (imported == 0) return null;

    final String? panoramaPath = await _findPanorama(stationId, records);
    if (imported >= required) {
      await _store.markSessionStatus(
        sessionId: stationId,
        status: CaptureSessionStatus.complete,
      );
    }
    if (panoramaPath != null) {
      await _store.savePanorama(
        sessionId: stationId,
        localPanoramaPath: panoramaPath,
        status: PanoramaGenerationStatus.ready,
      );
    }
    return (frames: imported, panorama: panoramaPath);
  }

  /// Finds the stitched panorama for a legacy station, preferring the path the
  /// stitcher recorded in `panorama.json` over a guessed file name.
  Future<String?> _findPanorama(
    String stationId,
    List<CaptureRecord> records,
  ) async {
    final stationDir = _stationDirectory(records);
    if (stationDir == null) return null;

    final manifest = File(p.join(stationDir, 'panorama.json'));
    if (await manifest.exists()) {
      try {
        final json =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        final recorded = json['panoramaPath'] as String?;
        if (recorded != null && await File(recorded).exists()) return recorded;
      } catch (error) {
        debugPrint('SITEWISE_IMPORT: $stationId panorama.json unreadable: $error');
      }
    }
    final conventional = p.join(stationDir, 'panorama.jpg');
    if (await File(conventional).exists()) return conventional;
    return null;
  }

  /// `<stationDir>/frames/t01.jpg` → `<stationDir>`.
  String? _stationDirectory(List<CaptureRecord> records) {
    final first = records.first.imagePath;
    final framesDir = p.dirname(first);
    if (p.basename(framesDir) == 'frames') return p.dirname(framesDir);
    // A station that stored its JPEGs flat: the directory itself is the station.
    return framesDir;
  }
}
