import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/capture_session_store.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/sitewise_database.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// A fresh in-memory database running the **real** DDL.
///
/// The point of these tests is the constraints — the composite primary key, the
/// `ON DELETE CASCADE`, the CHECK on `target_id`, the partial unique index on
/// `job_id`. A mocked store would pass all of them by accident, so the tests open
/// the production schema through `sqflite_common_ffi` instead.
///
/// `singleInstance: false` matters: it makes every call a genuinely separate
/// database rather than a handle onto the previous test's data.
Future<SitewiseDatabase> openTestDatabase() async {
  sqfliteFfiInit();
  return SitewiseDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
    singleInstance: false,
  );
}

/// A store plus its database, so a test can close both.
class TestStore {
  TestStore(this.database, this.store);

  final SitewiseDatabase database;
  final CaptureSessionStore store;

  Future<void> close() => database.close();
}

Future<TestStore> openTestStore({DateTime Function()? clock}) async {
  final database = await openTestDatabase();
  return TestStore(
    database,
    SqliteCaptureSessionStore(database, clock: clock),
  );
}

/// A temporary directory that deletes itself.
class TempWorkspace {
  TempWorkspace._(this.directory);

  final Directory directory;

  static Future<TempWorkspace> create() async =>
      TempWorkspace._(await Directory.systemTemp.createTemp('sitewise_test_'));

  String path(String relative) => '${directory.path}${Platform.pathSeparator}$relative';

  Future<File> writeFile(String relative, List<int> bytes) async {
    final file = File(path(relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

/// A structurally valid JPEG: SOI, a real SOF0 frame header, padding, EOI.
///
/// The upload path refuses a file it cannot parse, so a test that only wrote
/// `[0xFF, 0xD8, 0xFF, 0xD9]` would be testing the rejection path by accident.
/// This is 9 KiB of valid-looking JPEG that [PanoramaFileCheck] accepts.
Uint8List syntheticJpeg({int width = 4096, int height = 2048, int size = 9 * 1024}) {
  final bytes = Uint8List(size);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8; // SOI
  bytes[2] = 0xFF;
  bytes[3] = 0xC0; // SOF0
  bytes[4] = 0x00;
  bytes[5] = 0x0B; // segment length 11
  bytes[6] = 0x08; // precision
  bytes[7] = (height >> 8) & 0xFF;
  bytes[8] = height & 0xFF;
  bytes[9] = (width >> 8) & 0xFF;
  bytes[10] = width & 0xFF;
  bytes[11] = 0x03; // components
  // Padding stays zero; the parser stops at the SOF and the EOI ends the file.
  bytes[size - 2] = 0xFF;
  bytes[size - 1] = 0xD9; // EOI
  return bytes;
}

/// A frame row for [targetId], with a path inside [workspace].
CapturedFrame frameFor(
  String sessionId,
  int targetId, {
  required String imagePath,
  DateTime? capturedAt,
}) => CapturedFrame(
  sessionId: sessionId,
  targetId: targetId,
  imagePath: imagePath,
  capturedAt: capturedAt ?? DateTime.utc(2026, 11, 16, 10, targetId),
  targetYawDegrees: ((targetId - 1) % 12) * 30.0,
  targetPitchDegrees: 0,
  cameraOrientation: const Quat(0, 0, 0, 1),
  imageWidth: 3072,
  imageHeight: 4096,
  sourceImageWidth: 3072,
  sourceImageHeight: 4096,
  alignmentErrorDeg: 1.5,
  toleranceDeg: 5,
);
