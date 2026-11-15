import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_normalizer.dart';

void main() {
  test('reads a 4032 × 3024 SOF0 header', () {
    final bytes = Uint8List.fromList(<int>[
      0xFF, 0xD8, // SOI
      0xFF, 0xC0, 0x00, 0x11, // SOF0, segment length 17
      0x08, // sample precision
      0x0B, 0xD0, // height 3024
      0x0F, 0xC0, // width 4032
      0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
    ]);
    final size = readJpegSize(bytes);
    expect(size, isNotNull);
    expect(size!.width, 4032);
    expect(size.height, 3024);
  });

  test('skips an APP0 segment before the frame header', () {
    final builder = BytesBuilder();
    builder.add(<int>[0xFF, 0xD8]);
    builder.add(<int>[0xFF, 0xE0, 0x00, 0x10]); // length 16
    builder.add(List<int>.filled(14, 0));
    builder.add(<int>[
      0xFF,
      0xC0,
      0x00,
      0x11,
      0x08,
      0x0B,
      0xD0,
      0x0F,
      0xC0,
      0x03,
      0x01,
      0x11,
      0x00,
      0x02,
      0x11,
      0x01,
      0x03,
      0x11,
      0x01,
    ]);
    final size = readJpegSize(builder.toBytes());
    expect(size, isNotNull);
    expect(size!.width, 4032);
    expect(size.height, 3024);
  });

  test('reads a 16:9 frame so the normalizer can crop it', () {
    final bytes = Uint8List.fromList(<int>[
      0xFF, 0xD8,
      0xFF, 0xC0, 0x00, 0x11, 0x08,
      0x08, 0xDC, // height 2268
      0x0F, 0xC0, // width 4032
      0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
    ]);
    final size = readJpegSize(bytes);
    expect(size, isNotNull);
    expect(size!.width, 4032);
    expect(size.height, 2268);
    expect(size.width / size.height, closeTo(16 / 9, 0.001));
  });

  test('a portrait 3072 x 4096 frame is already 4:3', () {
    expect(isFourThree(4032, 3024), isTrue);
    expect(isFourThree(3072, 4096), isTrue);
    expect(isFourThree(4032, 2268), isFalse);
    expect(isFourThree(1080, 1920), isFalse);
    expect(isFourThree(0, 0), isFalse);
  });

  test('returns null for non-JPEG data', () {
    expect(readJpegSize(Uint8List.fromList(<int>[0, 1, 2, 3])), isNull);
    expect(
      readJpegSize(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9])),
      isNull,
    );
  });

  group('EXIF orientation', () {
    test('a 90° rotation reports the displayed portrait size', () {
      // Android writes the still in sensor orientation (landscape) and records
      // the rotation in EXIF. `imread` applies it, so the stitcher sees
      // 3024 × 4032 — and the recorded size has to say the same or the focal
      // length is derived from the wrong axis.
      final size = readJpegSize(_jpeg(orientation: 6, width: 4032, height: 3024));
      expect(size, isNotNull);
      expect(size!.width, 3024);
      expect(size.height, 4032);
    });

    test('a 270° rotation also swaps the axes', () {
      final size = readJpegSize(_jpeg(orientation: 8, width: 4032, height: 3024));
      expect(size!.width, 3024);
      expect(size.height, 4032);
    });

    test('orientation 1 leaves the axes alone', () {
      final size = readJpegSize(_jpeg(orientation: 1, width: 4032, height: 3024));
      expect(size!.width, 4032);
      expect(size.height, 3024);
    });

    test('a mirrored orientation still swaps', () {
      final size = readJpegSize(_jpeg(orientation: 7, width: 4000, height: 3000));
      expect(size!.width, 3000);
      expect(size.height, 4000);
    });

    test('a truncated APP1 segment does not throw', () {
      final bytes = _jpeg(orientation: 6, width: 4032, height: 3024);
      // Chop the TIFF header in half: the parser must fall back, not crash.
      final truncated = Uint8List.sublistView(bytes, 0, 12);
      expect(readJpegSize(truncated), isNull);
    });
  });
}

/// A minimal JPEG with one APP1/EXIF segment carrying [orientation].
///
/// Hand-built rather than fixture-based so the byte layout being parsed is
/// visible in the test itself.
Uint8List _jpeg({
  required int orientation,
  required int width,
  required int height,
}) {
  final tiff = <int>[
    0x49, 0x49, 0x2A, 0x00, // little-endian TIFF magic
    0x08, 0x00, 0x00, 0x00, // IFD0 at offset 8
    0x01, 0x00, // one entry
    0x12, 0x01, // tag 0x0112 = Orientation
    0x03, 0x00, // type 3 = SHORT
    0x01, 0x00, 0x00, 0x00, // count 1
    orientation, 0x00, 0x00, 0x00, // value
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ];
  final payload = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];

  final builder = BytesBuilder();
  builder.add(<int>[0xFF, 0xD8]); // SOI
  builder.add(<int>[0xFF, 0xE1]); // APP1
  final length = payload.length + 2;
  builder.add(<int>[(length >> 8) & 0xFF, length & 0xFF]);
  builder.add(payload);
  builder.add(<int>[
    0xFF, 0xC0, 0x00, 0x11, 0x08, //
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ]);
  builder.add(<int>[0xFF, 0xD9]); // EOI
  return builder.toBytes();
}
