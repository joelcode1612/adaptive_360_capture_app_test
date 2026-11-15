// Verification harness for the stitching isolate contract (specification
// test A) — runnable on the plain VM because `stitch_job_runner.dart` is
// pure Dart:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_stitch_isolate.dart
//
// It proves the reported failure is fixed: the old pattern — a closure that
// evaluates `receivePort.sendPort` *inside* the isolate — is demonstrated to
// throw the exact `_ReceivePortImpl` error, and the production
// [StitchJobRunner] then runs the same work successfully.
library;

import 'dart:async';
import 'dart:io' show exitCode, sleep, stdout;
import 'dart:isolate';

import 'package:adaptive_360_capture_app/features/sphere_capture/data/stitch_job_runner.dart';

int _passed = 0;
int _failed = 0;
String _current = '';

void check(bool ok, String detail) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $_current — $detail');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $_current — $detail');
  }
}

Future<void> scenario(String name, Future<void> Function() body) async {
  _current = name;
  stdout.writeln('\n=== $name ===');
  try {
    await body();
  } catch (e, st) {
    _failed++;
    stdout.writeln('  FAIL  $_current — threw $e\n$st');
  }
}

// ── top-level fake workers (a closure would not be sendable) ────────────────

({bool ok, String message}) progressWorker(StitchWorkerArgs args) {
  args.progress.send('stage one');
  args.progress.send('stage two');
  return (ok: true, message: 'done');
}

({bool ok, String message}) throwingWorker(StitchWorkerArgs args) {
  throw StateError('boom');
}

({bool ok, String message}) slowWorker(StitchWorkerArgs args) {
  // Blocks this worker isolate long enough for the duplicate check below to
  // observe the runner's in-flight guard.
  sleep(const Duration(milliseconds: 400));
  return (ok: true, message: 'slow done');
}

Future<void> main() async {
  await scenario(
    'the old ReceivePort-capturing closure is unsendable (the reported bug)',
    () async {
      final port = ReceivePort();
      Object? caught;
      try {
        await Isolate.run(() => port.sendPort);
      } catch (error) {
        caught = error;
      } finally {
        port.close();
      }
      check(
        caught is ArgumentError &&
            caught.toString().contains('unsendable'),
        'the closure-captured ReceivePort throws: $caught',
      );
    },
  );

  await scenario('the runner starts, relays progress and completes', () async {
    final stages = <String>[];
    final result = await StitchJobRunner.run(
      worker: progressWorker,
      stationDir: '/tmp/station-a',
      outPath: '/tmp/station-a/panorama.jpg',
      width: 2048,
      onStage: stages.add,
    );
    check(result.ok && result.message == 'done', 'worker returned ok');
    // Progress arrives asynchronously; give the port a moment to drain.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(
      stages.length == 2 && stages.first == 'stage one',
      'progress received in order: $stages',
    );
    check(
      !StitchJobRunner.isBusy('/tmp/station-a'),
      'the station is no longer marked busy',
    );
  });

  await scenario('worker errors are returned safely, with a stack', () async {
    Object? reported;
    StackTrace? reportedStack;
    final result = await StitchJobRunner.run(
      worker: throwingWorker,
      stationDir: '/tmp/station-b',
      outPath: '/tmp/station-b/panorama.jpg',
      width: 2048,
      onError: (Object error, StackTrace stack) {
        reported = error;
        reportedStack = stack;
      },
    );
    check(
      !result.ok && result.message.contains('boom'),
      'failure carries the worker message: ${result.message}',
    );
    check(
      reported is StateError && reportedStack != null,
      'onError received the error and a stack trace',
    );
    check(
      !StitchJobRunner.isBusy('/tmp/station-b'),
      'a failed run still releases the busy flag',
    );
  });

  await scenario('duplicate retries never create concurrent jobs', () async {
    final first = StitchJobRunner.run(
      worker: slowWorker,
      stationDir: '/tmp/station-c',
      outPath: '/tmp/station-c/panorama.jpg',
      width: 2048,
    );
    final second = await StitchJobRunner.run(
      worker: slowWorker,
      stationDir: '/tmp/station-c',
      outPath: '/tmp/station-c/panorama.jpg',
      width: 2048,
    );
    check(
      !second.ok && second.message.contains('already being generated'),
      'the second request was refused: ${second.message}',
    );
    final firstResult = await first;
    check(firstResult.ok, 'the first request still completed');
    check(
      !StitchJobRunner.isBusy('/tmp/station-c'),
      'resources released after completion',
    );
    // A retry after completion is allowed — this is the Retry button path.
    final retry = await StitchJobRunner.run(
      worker: progressWorker,
      stationDir: '/tmp/station-c',
      outPath: '/tmp/station-c/panorama.jpg',
      width: 2048,
    );
    check(retry.ok, 'retry after completion succeeds without recapturing');
  });

  stdout.writeln('\n===== $_passed passed, $_failed failed =====');
  if (_failed > 0) exitCode = 1;
}
