import 'dart:io';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Interactive 360° equirectangular viewer for the stitched panorama.
///
/// The viewer is only ever handed a path the stitching service verified; a
/// missing file shows the reason instead of an empty sphere.
class SpherePanoramaScreen extends StatelessWidget {
  const SpherePanoramaScreen({super.key, required this.panoramaPath});

  final String panoramaPath;

  @override
  Widget build(BuildContext context) {
    final file = File(panoramaPath);
    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      appBar: AppBar(
        backgroundColor: CaptureColors.cameraChrome,
        foregroundColor: Colors.white,
        title: const Text('360° Panorama'),
      ),
      body: !file.existsSync()
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'The panorama file is not on disk. Return to the capture and '
                  'regenerate it — the $kSphereTargetCount photographs are '
                  'still saved.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CaptureColors.mutedOnDark),
                ),
              ),
            )
          : PanoramaViewer(
              sensorControl: SensorControl.orientation,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(
                  child: Text(
                    'The panorama could not be decoded.',
                    style: TextStyle(color: CaptureColors.mutedOnDark),
                  ),
                ),
              ),
            ),
    );
  }
}
