import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_size.dart';

/// Why a local panorama is not uploadable.
enum PanoramaFileIssue {
  /// Nothing wrong.
  none,

  /// No path was recorded, or nothing is at it.
  missing,

  /// Present but far too small to be a panorama.
  tooSmall,

  /// Not a JPEG at all (no SOI marker).
  notJpeg,

  /// A JPEG header with no frame header, or one truncated before its EOI.
  truncated,
}

/// A structural check that the panorama on disk is a real, complete JPEG.
///
/// ## What "can be decoded" means here
///
/// The requirement is that the app never uploads a file it cannot render. A
/// full pixel decode needs `dart:ui`, which only exists with a Flutter binding
/// and would make this check untestable in a plain unit test. Instead the file
/// is parsed: a valid SOI marker, a reachable SOF frame header (via
/// [readJpegSize], the same parser the capture path already trusts for its 4:3
/// check), and an EOI marker at the end.
///
/// That catches the three failures that actually happen — a zero-byte file from
/// a killed write, a truncated file from a full disk, and a PNG or a text file
/// at a `.jpg` path — without pretending to be a codec. The viewer still
/// decodes the image for real before the user sees it, so a file that passes
/// here and fails there is a rendering bug, not an upload bug.
class PanoramaFileCheck {
  const PanoramaFileCheck._();

  /// The smallest plausible equirectangular JPEG. A 360° panorama is megabytes;
  /// anything under 8 KiB is a placeholder, not a panorama.
  static const int minimumBytes = 8 * 1024;

  static Future<PanoramaFileIssue> inspect(String? path) async {
    if (path == null || path.isEmpty) return PanoramaFileIssue.missing;
    final file = File(path);
    if (!await file.exists()) return PanoramaFileIssue.missing;
    final length = await file.length();
    if (length < minimumBytes) return PanoramaFileIssue.tooSmall;

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      return PanoramaFileIssue.missing;
    }
    if (bytes.length < 4) return PanoramaFileIssue.tooSmall;
    // SOI: FF D8. Every JPEG begins with it, and no other format does.
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return PanoramaFileIssue.notJpeg;
    // A frame header proves the encoder finished the header; a missing SOF is
    // what a truncated write looks like.
    if (readJpegSize(bytes) == null) return PanoramaFileIssue.truncated;
    // EOI: FF D9. Without it the scan data was cut short, and a decoder will
    // render the top band and grey out the rest.
    final tail = bytes.length - 2;
    if (bytes[tail] != 0xFF || bytes[tail + 1] != 0xD9) {
      return PanoramaFileIssue.truncated;
    }
    return PanoramaFileIssue.none;
  }

  /// A sentence for the user, or `null` when the file is fine.
  static String? describe(PanoramaFileIssue issue) => switch (issue) {
    PanoramaFileIssue.none => null,
    PanoramaFileIssue.missing =>
      'The panorama file is no longer on this device. Reopen the capture to '
          'regenerate it from the 38 photographs, which are still saved.',
    PanoramaFileIssue.tooSmall =>
      'The panorama file is empty or incomplete, so it was not uploaded. '
          'Regenerate it from the saved photographs.',
    PanoramaFileIssue.notJpeg =>
      'The file at the panorama path is not a JPEG, so it was not uploaded.',
    PanoramaFileIssue.truncated =>
      'The panorama file is incomplete — the write was interrupted. Regenerate '
          'it from the saved photographs.',
  };
}
