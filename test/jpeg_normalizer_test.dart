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
}
