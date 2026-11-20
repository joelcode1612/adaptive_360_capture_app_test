import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';

/// Local persistence for Section 1 capture data.
///
/// Filesystem layout, under the app's private documents directory (the same
/// choice the existing session store makes: these are the user's photographs of
/// their own premises and they must not land in shared storage):
///
/// ```
/// <appDocs>/ar_capture/
///   <stationId>/
///     station.json      the calibrated reference pose
///     targets.json      the 26 targets, with anchor + status
///     records.json      one entry per saved photograph
///     frames/
///       t01.jpg … t30.jpg
/// ```
///
/// No backend is involved in capturing a photograph. Everything a review screen
/// needs is on disk before the target is marked done.
abstract class CaptureRepository {
  Future<void> saveStation(CaptureStation station);

  Future<void> saveTargets(List<CaptureTarget> targets);

  /// Persists a complete calibrated station only after all AR placements exist.
  /// Implementations stage both metadata files and roll back on failure.
  Future<void> saveCalibration(
    CaptureStation station,
    List<CaptureTarget> targets,
  );

  Future<void> saveRecord(CaptureRecord record);

  Future<CaptureStation?> loadStation(String stationId);

  Future<List<CaptureTarget>> loadTargets(String stationId);

  Future<List<CaptureRecord>> loadRecords(String stationId);

  /// Absolute path of the JPEG for [stationId]/[targetId].
  Future<String> framePath(String stationId, int targetId);

  /// Every station that has been saved, newest first.
  ///
  /// The resume entry point needs this to offer "continue where you left off"
  /// without the caller knowing anything about the store's layout.
  Future<List<String>> stationIds();
}

/// Commits the station and its complete target set as one recoverable local
/// transaction. A pending marker keeps incomplete work out of resume discovery;
/// backups let an interrupted or failed replacement restore the previous
/// accepted calibration without touching records or JPEG files.
Future<void> persistCaptureCalibrationFiles({
  required String stationDirectory,
  required CaptureStation station,
  required List<CaptureTarget> targets,
}) async {
  if (targets.length != station.total ||
      targets.any((CaptureTarget t) => t.stationId != station.stationId) ||
      targets.map((CaptureTarget t) => t.targetId).toSet().length !=
          station.total) {
    throw StateError(
      'Calibration must contain the complete unique target set.',
    );
  }

  final directory = Directory(stationDirectory);
  await directory.create(recursive: true);
  final stationFile = File(p.join(stationDirectory, 'station.json'));
  final targetsFile = File(p.join(stationDirectory, 'targets.json'));
  final pending = File(p.join(stationDirectory, '.calibration.pending'));
  final stationTemp = File(p.join(stationDirectory, '.station.json.pending'));
  final targetsTemp = File(p.join(stationDirectory, '.targets.json.pending'));
  final stationBackup = File(
    p.join(stationDirectory, '.station.json.calibration-backup'),
  );
  final targetsBackup = File(
    p.join(stationDirectory, '.targets.json.calibration-backup'),
  );

  if (await pending.exists()) {
    await _rollbackPendingCalibration(stationDirectory);
  }
  await _deleteIfExists(stationBackup);
  await _deleteIfExists(targetsBackup);
  await _deleteIfExists(stationTemp);
  await _deleteIfExists(targetsTemp);

  final hadStation = await stationFile.exists();
  final hadTargets = await targetsFile.exists();
  await pending.writeAsString(
    jsonEncode(<String, Object?>{
      'hadStation': hadStation,
      'hadTargets': hadTargets,
    }),
    flush: true,
  );

  try {
    await stationTemp.writeAsString(jsonEncode(station.toJson()), flush: true);
    await targetsTemp.writeAsString(
      jsonEncode(targets.map((CaptureTarget t) => t.toJson()).toList()),
      flush: true,
    );

    if (hadStation) await stationFile.rename(stationBackup.path);
    if (hadTargets) await targetsFile.rename(targetsBackup.path);
    await targetsTemp.rename(targetsFile.path);
    await stationTemp.rename(stationFile.path);

    final savedStation = CaptureStation.fromJson(
      jsonDecode(await stationFile.readAsString()) as Map<String, dynamic>,
    );
    final savedTargets = (jsonDecode(await targetsFile.readAsString()) as List)
        .map(
          (dynamic row) => CaptureTarget.fromJson(row as Map<String, dynamic>),
        )
        .toList(growable: false);
    if (savedStation.stationId != station.stationId ||
        savedTargets.length != station.total ||
        savedTargets.any(
          (CaptureTarget t) => t.stationId != station.stationId,
        )) {
      throw StateError('Calibration verification failed after persistence.');
    }

    // Removing this marker is the commit point: station discovery ignores the
    // directory until both complete files have been verified.
    await pending.delete();
    await _deleteIfExists(stationBackup, ignoreErrors: true);
    await _deleteIfExists(targetsBackup, ignoreErrors: true);
  } catch (_) {
    try {
      await _rollbackPendingCalibration(stationDirectory);
    } catch (_) {
      // Keep the marker if rollback itself fails. Resume discovery will refuse
      // this directory rather than advertise a partial station as calibrated.
    }
    rethrow;
  }
}

Future<void> _rollbackPendingCalibration(String stationDirectory) async {
  final pending = File(p.join(stationDirectory, '.calibration.pending'));
  if (!await pending.exists()) return;
  final metadata =
      jsonDecode(await pending.readAsString()) as Map<String, dynamic>;
  final stationFile = File(p.join(stationDirectory, 'station.json'));
  final targetsFile = File(p.join(stationDirectory, 'targets.json'));
  final stationBackup = File(
    p.join(stationDirectory, '.station.json.calibration-backup'),
  );
  final targetsBackup = File(
    p.join(stationDirectory, '.targets.json.calibration-backup'),
  );

  Future<void> restore(File current, File backup, bool existedBefore) async {
    if (existedBefore) {
      if (await backup.exists()) {
        await _deleteIfExists(current);
        await backup.rename(current.path);
      }
    } else {
      await _deleteIfExists(current);
    }
  }

  await restore(stationFile, stationBackup, metadata['hadStation'] == true);
  await restore(targetsFile, targetsBackup, metadata['hadTargets'] == true);
  await _deleteIfExists(
    File(p.join(stationDirectory, '.station.json.pending')),
  );
  await _deleteIfExists(
    File(p.join(stationDirectory, '.targets.json.pending')),
  );
  await pending.delete();
}

Future<void> _deleteIfExists(File file, {bool ignoreErrors = false}) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    if (!ignoreErrors) rethrow;
  }
}

class FileCaptureRepository implements CaptureRepository {
  FileCaptureRepository(this._root);

  final String _root;

  /// Builds one against the platform's documents directory.
  static Future<FileCaptureRepository> create() async {
    final docs = await getApplicationDocumentsDirectory();
    return FileCaptureRepository(p.join(docs.path, 'ar_capture'));
  }

  String _stationDir(String stationId) => p.join(_root, stationId);

  String get _framesName => 'frames';

  Future<String> _framesDir(String stationId) async {
    final dir = Directory(p.join(_stationDir(stationId), _framesName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> framePath(String stationId, int targetId) async {
    final dir = await _framesDir(stationId);
    return p.join(dir, 't${targetId.toString().padLeft(2, '0')}.jpg');
  }

  @override
  Future<void> saveStation(CaptureStation station) async {
    final file = File(p.join(_stationDir(station.stationId), 'station.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(station.toJson()), flush: true);
  }

  @override
  Future<void> saveTargets(List<CaptureTarget> targets) async {
    if (targets.isEmpty) return;
    final file = File(
      p.join(_stationDir(targets.first.stationId), 'targets.json'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(
        targets.map((CaptureTarget t) => t.toJson()).toList(growable: false),
      ),
      flush: true,
    );
  }

  @override
  Future<void> saveCalibration(
    CaptureStation station,
    List<CaptureTarget> targets,
  ) => persistCaptureCalibrationFiles(
    stationDirectory: _stationDir(station.stationId),
    station: station,
    targets: targets,
  );

  @override
  Future<void> saveRecord(CaptureRecord record) async {
    final file = File(p.join(_stationDir(record.stationId), 'records.json'));
    await file.parent.create(recursive: true);
    // A defensive copy: `loadRecords` answers with the shared empty list when
    // no file exists yet, and `removeWhere` on it threw — so the *first*
    // record of every station could never be written. A growable copy also
    // keeps the caller's list, and the loaded one, independent.
    final existing = List<CaptureRecord>.of(
      await loadRecords(record.stationId),
    );
    // Replace by target, so a retake overwrites the old evidence instead of
    // appending a second record for the same photograph.
    existing.removeWhere((CaptureRecord r) => r.targetId == record.targetId);
    existing.add(record);
    existing.sort(
      (CaptureRecord a, CaptureRecord b) => a.targetId.compareTo(b.targetId),
    );
    final contents = jsonEncode(
      existing.map((CaptureRecord r) => r.toJson()).toList(growable: false),
    );
    final temporary = File('${file.path}.partial');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  }

  @override
  Future<CaptureStation?> loadStation(String stationId) async {
    final file = File(p.join(_stationDir(stationId), 'station.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    return CaptureStation.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<CaptureTarget>> loadTargets(String stationId) async {
    final file = File(p.join(_stationDir(stationId), 'targets.json'));
    if (!await file.exists()) return const <CaptureTarget>[];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return json
        .map((dynamic e) => CaptureTarget.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<CaptureRecord>> loadRecords(String stationId) async {
    final file = File(p.join(_stationDir(stationId), 'records.json'));
    if (!await file.exists()) return const <CaptureRecord>[];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return json
        .map((dynamic e) => CaptureRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Every station that has been saved, newest first.
  @override
  Future<List<String>> stationIds() async {
    final dir = Directory(_root);
    if (!await dir.exists()) return const <String>[];
    final ids = dir
        .listSync()
        .whereType<Directory>()
        .map((Directory d) => p.basename(d.path))
        .toList();
    // A station directory only counts once it holds a station record; a
    // half-written directory from a killed process is not a station.
    final result = <String>[];
    for (final id in ids) {
      final stationDirectory = _stationDir(id);
      if (await File(
        p.join(stationDirectory, '.calibration.pending'),
      ).exists()) {
        continue;
      }
      if (await File(p.join(stationDirectory, 'station.json')).exists()) {
        result.add(id);
      }
    }
    return result;
  }
}
