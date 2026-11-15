// Pure JPEG size and EXIF-orientation parsing.
//
// Extracted from `jpeg_normalizer.dart` so the size/EXIF logic can be tested
// on the plain VM (`tool/verify_sphere_projection.dart`, Test D) — the
// normalizer itself needs OpenCV for cropping and cannot load where the
// native toolchain is unavailable.
//
// ## EXIF orientation
//
// The dimensions returned are **as displayed**, not as stored. Android's
// camera writes the JPEG in sensor orientation (landscape) and records a
// rotation in EXIF; OpenCV's `imread` applies that rotation, so the stitcher
// sees a portrait image while the SOF marker still says landscape. Returning
// the raw SOF size therefore described a 3024 × 4032 photograph as
// 4032 × 3024, and the stitcher — which derives its focal length from the
// recorded height — used the *width* as the vertical field of view and
// under-estimated the lens by 25%. Reading the orientation tag is what makes
// the recorded size agree with the decoded image.
library;

import 'dart:typed_data';

/// Whether the JPEG's EXIF orientation tag rotates the stored pixels for
/// display (values 5–8 swap width and height).
({int width, int height})? readJpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  final orientation = exifOrientation(bytes);
  final swapAxes = orientation != null && orientation >= 5 && orientation <= 8;
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    // Standalone markers carry no length field.
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0xFF) {
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) return null;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    final isStartOfFrame =
        (marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF);
    if (isStartOfFrame) {
      if (i + 8 >= bytes.length) return null;
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width <= 0 || height <= 0) return null;
      return swapAxes
          ? (width: height, height: width)
          : (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}

/// The EXIF orientation tag (0x0112) of [bytes], or `null` when absent.
///
/// Only the first APP1 segment is inspected: the orientation tag lives in IFD0
/// of the primary image, and a thumbnail's IFD1 — which could carry a different
/// value — is never reached because the search stops at the first match.
int? exifOrientation(Uint8List bytes) {
  var i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0xFF) {
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) return null;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    // Entropy-coded data starts here; no more metadata can follow.
    if (marker == 0xDA) return null;
    if (marker == 0xE1) {
      final start = i + 4;
      final end = i + 2 + length;
      if (end > bytes.length) return null;
      if (end - start >= 6 &&
          bytes[start] == 0x45 &&
          bytes[start + 1] == 0x78 &&
          bytes[start + 2] == 0x69 &&
          bytes[start + 3] == 0x66) {
        return _tiffOrientation(bytes, start + 6, end);
      }
    }
    i += 2 + length;
  }
  return null;
}

/// Reads tag 0x0112 out of a TIFF header embedded at [base].
int? _tiffOrientation(Uint8List b, int base, int end) {
  if (base + 8 > end) return null;
  final littleEndian = b[base] == 0x49 && b[base + 1] == 0x49;
  int u16(int o) =>
      littleEndian ? (b[o] | (b[o + 1] << 8)) : ((b[o] << 8) | b[o + 1]);
  int u32(int o) => littleEndian
      ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24))
      : ((b[o] << 24) |
            (b[o + 1] << 16) |
            (b[o + 2] << 8) |
            b[o + 3]);
  if (u16(base + 2) != 42) return null;
  final ifd = base + u32(base + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final entry = ifd + 2 + k * 12;
    if (entry + 12 > end) return null;
    if (u16(entry) != 0x0112) continue;
    // Type 3 is SHORT, which is the only type the tag is defined with.
    if (u16(entry + 2) != 3) return null;
    final value = u16(entry + 8);
    return value >= 1 && value <= 8 ? value : null;
  }
  return null;
}
