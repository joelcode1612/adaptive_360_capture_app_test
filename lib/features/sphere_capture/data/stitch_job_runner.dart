import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';

/// The transferable work order for a projection isolate.
///
/// A record of plain data — strings, an int and a [SendPort]. Nothing in it is
/// bound to the calling isolate, which is the whole point: the previous
/// implementation evaluated `progressPort.sendPort` *inside* the
/// `Isolate.run` closure, so the closure captured the `ReceivePort` itself and
/// the hand-off failed with:
///
/// ```text
/// Illegal argument in isolate message: object is unsendable
/// Class: _ReceivePortImpl
/// field progressPort in ...stitchFrames.<anonymous closure>
/// ```
typedef StitchWorkerArgs = ({
  String stationDir,
  String outPath,
  int width,
  SendPort progress,
});

/// The isolate entry point contract. Must be a **top-level or static**
/// function so a reference to it is sendable; a closure over instance state
/// is not.
typedef StitchWorker =
    ({bool ok, String message}) Function(StitchWorkerArgs args);

/// Runs one projection worker on a background isolate and relays its progress.
///
/// This class is the entire isolate contract, kept free of OpenCV and Flutter
/// widgets so it can be exercised on the plain VM:
///
/// * the [ReceivePort] stays here — only its `SendPort` is placed in the
///   sendable [args] record;
/// * the isolate closure captures `worker` (a top-level function) and `args`
///   (plain data) and nothing else;
/// * the listener and port are always released in `finally`;
/// * a second run for the same station while one is in flight is refused, so
///   a double-tapped Retry can never spawn two writers for one `panorama.jpg`;
/// * worker errors are caught, logged with their stack, and returned as a
///   failure — the caller's photographs are never touched.
class StitchJobRunner {
  StitchJobRunner._();

  /// Stations with a projection in flight.
  static final Set<String> _activeStations = <String>{};

  /// Whether a projection is running for [stationDir].
  static bool isBusy(String stationDir) =>
      _activeStations.contains(stationDir);

  /// Runs [worker] for one station on a background isolate.
  ///
  /// The [StitchWorkerArgs] record is assembled here, in the calling isolate,
  /// so the `SendPort` is always read on the correct side of the boundary.
  /// [onStage] receives every progress string the worker sends. [onError] is
  /// called (in the calling isolate) with the error and stack trace when the
  /// worker throws or the isolate hand-off fails.
  static Future<({bool ok, String message})> run({
    required StitchWorker worker,
    required String stationDir,
    required String outPath,
    required int width,
    void Function(String stage)? onStage,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    if (!_activeStations.add(stationDir)) {
      return (
        ok: false,
        message:
            'A panorama is already being generated for this station. Wait '
            'for it to finish.',
      );
    }
    final progressPort = ReceivePort();
    // Read the sendable value out HERE, in this isolate. This one line is the
    // fix: evaluating `sendPort` inside the closure below would capture the
    // ReceivePort and make the isolate message unsendable.
    final SendPort progress = progressPort.sendPort;
    final args = (
      stationDir: stationDir,
      outPath: outPath,
      width: width,
      progress: progress,
    );
    final subscription = progressPort.listen((dynamic message) {
      if (message is String) onStage?.call(message);
    });
    try {
      return await _runWorkerOnIsolate(worker, args);
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
      // `dart:developer` rather than Flutter's debugPrint: the stack trace is
      // attached to the log entry, and this file stays loadable on the plain
      // VM so the isolate contract is testable without a Flutter engine.
      developer.log(
        'SPHERE_STITCH: projection failed',
        name: 'sitewise.sphere',
        error: error,
        stackTrace: stackTrace,
      );
      return (ok: false, message: 'Panorama projection failed: $error');
    } finally {
      _activeStations.remove(stationDir);
      await subscription.cancel();
      progressPort.close();
    }
  }
}

/// Runs the worker on a background isolate.
///
/// **Top-level on purpose.** The closure below captures only this function's
/// two parameters — `worker` (a top-level function reference) and `args` (a
/// record of strings, an int and a `SendPort`). Both are sendable.
///
/// The previous version wrote `Isolate.run(() => worker(args))` inline inside
/// [StitchJobRunner.run]. Dart closures capture their enclosing *context*, not
/// just the names they mention, so that closure also carried `run`'s
/// `onStage`/`onError` parameters — callbacks that close over the Flutter
/// controller, and through it `_stitchFuture`. The isolate hand-off therefore
/// failed with:
///
/// ```text
/// Illegal argument in isolate message: object is unsendable
/// Class: _Future
/// ```
///
/// Keeping the isolate launch in its own top-level function gives the closure
/// a scope that contains nothing but transferable data, so callbacks and
/// controller state can never leak into the message.
Future<({bool ok, String message})> _runWorkerOnIsolate(
  StitchWorker worker,
  StitchWorkerArgs args,
) => Isolate.run(() => worker(args));
