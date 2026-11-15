"""Apply the focused 38-photo panorama performance fix (version 2).

Run from the root of adaptive_360_capture_app_test:
    python apply_sitewise_stitch_fix_v2.py

Requires only Python 3. Creates a .bak copy of the original file.
Does not touch captured photographs or any files outside the target Dart file.
Safely skips the optional longitude repair if local source differs.
"""
from pathlib import Path
import sys

TARGET = Path('lib/features/sphere_capture/data/equirectangular_stitcher.dart')


def replace_once(source: str, before: str, after: str, label: str) -> str:
    count = source.count(before)
    if count != 1:
        raise ValueError(f'{label}: expected exactly one source match, found {count}; no file was changed')
    return source.replace(before, after, 1)


def update_seam_if_safe(source: str) -> tuple[str, bool]:
    """Conservatively repair the old longitude bounding bug when recognizable.

    This deliberately DOES NOT require any specific comment wording or the
    initial `var minLon = 10.0;` text. Unknown local variants are left alone.
    """
    import re
    start = source.find('\n_lonLatBounds(')
    end = source.find('\ndouble _unwrap(', start)
    if start < 0 or end < 0:
        return source, False
    block = source[start:end]
    if 'final lon = _unwrap(' in block:
        return source, False
    if 'final lon = math.atan2(dir.x, -dir.z);' not in block:
        return source, False
    if not re.search(r'(?m)^  var minLon\s*=', block):
        return source, False
    # The code previously unwrapped the min/max only after evaluating extrema.
    # We must remove the old centreLon declaration and the two unwrapping calls.
    old_decl = re.search(
        r'  final centreLon\s*=\s*math\.atan2\(\s*'
        r'cameraToSphere\.rotate\(const Vec3\(0, 0, -1\)\)\.x,\s*'
        r'-cameraToSphere\.rotate\(const Vec3\(0, 0, -1\)\)\.z,\s*'
        r'\);\s*minLon\s*=\s*_unwrap\(minLon, centreLon\);\s*'
        r'maxLon\s*=\s*_unwrap\(maxLon, centreLon\);',
        block,
        flags=re.S,
    )
    if old_decl is None:
        return source, False
    block = block[:old_decl.start()] + block[old_decl.end():]
    block = block.replace(
        '  var minLon',
        '  // Unwrap every boundary sample relative to the frame heading.\n'
        '  final forward = cameraToSphere.rotate(const Vec3(0, 0, -1));\n'
        '  final centreLon = math.atan2(forward.x, -forward.z);\n'
        '  var minLon',
        1,
    )
    block = block.replace(
        'final lon = math.atan2(dir.x, -dir.z);',
        'final lon = _unwrap(math.atan2(dir.x, -dir.z), centreLon);',
        1,
    )
    return source[:start] + block + source[end:], True


def main():
    if not TARGET.is_file():
        print(f'ERROR: {TARGET} not found. Run from the repository root.', file=sys.stderr)
        return 1
    original = TARGET.read_text(encoding='utf-8')
    source = original

    source = replace_once(source, '''    onStage?.call('Projecting ${imagePaths.length} photographs…');
    try {
      final result = await Isolate.run(
        () => _projectEquirect(stationDir, outPath, width),
      );
      if (!result.ok) return StitchResult.failure(result.message);
      return StitchResult(
        success: true,
        panoramaPath: outPath,
        message: 'Panorama generated successfully.',
      );
    } catch (error) {
      return StitchResult.failure('Panorama projection failed: $error');
    }''', '''    // ReceivePort reports progress from the compute isolate without blocking UI.
    final progressPort = ReceivePort();
    final progressSubscription = progressPort.listen((dynamic message) {
      if (message is String) onStage?.call(message);
    });
    onStage?.call('Preparing ${imagePaths.length} photographs…');
    try {
      final result = await Isolate.run(
        () => _projectEquirect(stationDir, outPath, width, progressPort.sendPort),
      );
      if (!result.ok) return StitchResult.failure(result.message);
      return StitchResult(
        success: true,
        panoramaPath: outPath,
        message: 'Panorama generated successfully.',
      );
    } catch (error) {
      return StitchResult.failure('Panorama projection failed: $error');
    } finally {
      await progressSubscription.cancel();
      progressPort.close();
    }''', 'isolate progress')

    source = replace_once(source, '''  String outPath,
  int width,
) {
  final recordsFile =''', '''  String outPath,
  int width,
  SendPort progress,
) {
  final stopwatch = Stopwatch()..start();
  final recordsFile =''', 'isolate signature')

    source = replace_once(source, '''  for (final record in records) {
    final path = record['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) {
      return (ok: false, message: 'A captured photograph is missing: $path');
    }
    final mat = cv.imread(path, flags: cv.IMREAD_COLOR);''', '''  // Decode JPEGs at a resolution appropriate for the output. A 2048-wide
  // equirectangular panorama does not need 38 full-resolution 12 MP buffers.
  // OpenCV's reduced decoder uses scaled-IDCT, reducing allocations/decoding.
  // Preserve more detail for optional higher-resolution panoramas.
  final decodeFlag = width <= 2048
      ? cv.IMREAD_REDUCED_COLOR_4
      : width <= 4096
          ? cv.IMREAD_REDUCED_COLOR_2
          : cv.IMREAD_COLOR;
  for (var frameIndex = 0; frameIndex < records.length; frameIndex++) {
    final record = records[frameIndex];
    final path = record['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) {
      return (ok: false, message: 'A captured photograph is missing: $path');
    }
    final mat = cv.imread(path, flags: decodeFlag);''', 'reduced JPEG decode')

    source = replace_once(source, '''      final rowStride = imageWidth * 3;

      final bounds =''', '''      final rowStride = imageWidth * 3;
      final marginX = 0.05 * imageWidth;
      final marginY = 0.05 * imageHeight;

      final bounds =''', 'pixel-loop margin hoist')

    source = replace_once(source, '''          final x = ((xi % width) + width) % width;''', '''          // The longitude interval extends by at most one panorama wrap.
          // Avoid two integer modulo operations in the hot pixel loop.
          final x = xi < 0
              ? xi + width
              : (xi >= width ? xi - width : xi);''', 'pixel-loop fast wrapping')

    source = replace_once(source, '''          final marginX = 0.05 * imageWidth;
          final marginY = 0.05 * imageHeight;
          weight *=''', '''          weight *=''', 'remove repeated margin work')

    source = replace_once(source, '''    } finally {
      mat.dispose();
    }
  }

  // Nearest frame per pixel''', '''    } finally {
      mat.dispose();
    }
    progress.send(
      'Projecting photographs: ${frameIndex + 1}/${records.length} '
      '(${stopwatch.elapsed.inSeconds}s elapsed)…',
    );
  }

  progress.send('Blending panorama and encoding JPEG…');
  // Nearest frame per pixel''', 'photo-level progress')

    # Local branches often change comments or longitude-bound implementation.
    # Patch it only when a recognisable old algorithm is present. Never reject
    # the performance fix just because this optional block has diverged.
    source, seam_updated = update_seam_if_safe(source)
    if seam_updated:
        print('Longitude seam: corrected per-sample unwrapping.')
    else:
        print('Longitude seam: not changed (already updated or local algorithm differs).')

    backup = TARGET.with_suffix('.dart.bak')
    if backup.exists():
        backup = TARGET.with_suffix('.dart.bak.v2')
    if backup.exists():
        print(f'ERROR: backup {backup} already exists; source unchanged.', file=sys.stderr)
        return 2
    if 'IMREAD_REDUCED_COLOR_4' not in source or 'SendPort progress' not in source:
        print('ERROR: post-patch check failed; source unchanged.', file=sys.stderr)
        return 3
    if source == original:
        print('No change needed.')
        return 0
    backup.write_text(original, encoding='utf-8')
    tmp = TARGET.with_suffix('.dart.patch-v2.tmp')
    try:
        tmp.write_text(source, encoding='utf-8')
        tmp.replace(TARGET)
    finally:
        if tmp.exists():
            tmp.unlink()
    print(f'Updated: {TARGET}\nBackup: {backup}')
    print('38 saved photos, target geometry, and panorama output dimensions were not changed.')
    print('Next: dart format lib/features/sphere_capture/data/equirectangular_stitcher.dart')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
