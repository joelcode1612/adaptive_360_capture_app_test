import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/cloud/sitewise_auth.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/presentation/screens/sphere_capture_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_flow_screen.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/screens/virtual_tour_camera_screen.dart';

/// SiteWise 360° Capture — the capture app.
///
/// Portrait only. The capture plan is defined by yaw and pitch around a standing
/// person, the target grid assumes the phone's long side is vertical, and the
/// reference is a phone-shaped column — so rotating the activity would change
/// what the guidance means, not merely how it looks. The lock is applied here
/// rather than in the manifest so the same Dart entry behaves identically under
/// `flutter test`.
///
/// **Portrait-up, not both portraits.** The capture plan assumes a vertical
/// phone. The AR screen still forwards metric changes to Android, where the
/// host refreshes ARCore's display geometry, but portrait-up keeps the capture
/// directions and the user-facing guidance semantically stable.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Supabase Auth is the only identity provider. Initialising it here means the
  // session is restored once, before any screen asks who is signed in; the call
  // is a no-op (and logs why) when the build has no project configured, which is
  // a supported offline-only configuration.
  await SitewiseSupabase.ensureInitialised();
  runApp(const VirtualTourApp());
}

class VirtualTourApp extends StatelessWidget {
  const VirtualTourApp({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    return MaterialApp(
      // The brief's §2 display name. `android:label` in the manifest is what the
      // launcher shows; this is what the OS task switcher and the window title
      // use, and the two agreeing is the only reason either is trustworthy.
      title: 'SiteWise 360° Capture',
      debugShowCheckedModeBanner: false,
      // Two themes, each with one job. [captureLightTheme] is the SiteWise
      // white surface the launcher and the light screens use; the camera
      // screens opt into [captureAppTheme] themselves, because a viewfinder
      // cannot be shown on white. `themeMode` is pinned rather than left to the
      // system: a phone in dark mode must not turn the white screens dark.
      theme: captureLightTheme(),
      themeMode: ThemeMode.light,
      home: const CaptureLauncher(),
    );
  }
}

/// Entry point: which capture path to run.
///
/// Three, and the difference is stated rather than hidden:
///
/// * **AR 360° Capture (26 Targets)** is the 3DoF sphere-follows-phone flow.
///   The sphere's centre is the phone, only rotation is tracked, and the
///   targets are projected from the device quaternion — no ARCore session, no
///   planes, no anchors and no calibration.
/// * **Virtual tour** is the 30-node station: a 1.0 m world-locked sphere, the
///   GLB target at every node, an automatic shutter, then upload and stitching.
///   Android/ARCore only, and deliberately separate from the 3DoF flow.
/// * **Guided flow** is the existing sensor-guided prototype port, which runs
///   anywhere and needs no AR.
class CaptureLauncher extends StatelessWidget {
  const CaptureLauncher({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: SiteWiseColors.paper,
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        children: [
          const _Brand(),
          const SizedBox(height: 26),
          _LaunchCard(
            title: 'AR 360° Capture (38 Targets)',
            subtitle:
                'Sphere-follows-phone capture with an automatic shutter and an '
                'on-device 360° panorama. No ARCore, no calibration, no drift.',
            icon: Icons.threesixty,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SphereCaptureScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LaunchCard(
            title: 'Virtual tour · 30 nodes',
            subtitle:
                'World-locked ARCore markers with automatic capture, then '
                'upload and stitching. Android with ARCore only.',
            icon: Icons.explore_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const VirtualTourCameraScreen(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _LaunchCard(
            title: 'Guided flow',
            subtitle:
                'Room details, capture plan, 26 guided views and the review '
                'screens. Runs without AR.',
            icon: Icons.photo_camera_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const CaptureFlowScreen(),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const _ShellNote(),
        ],
      ),
    ),
  );
}

/// The reference's `.brand`: a blue mark, a product name and a one-line role.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: SiteWiseColors.primary,
          borderRadius: BorderRadius.circular(13),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.threesixty, color: Colors.white, size: 26),
      ),
      const SizedBox(width: 12),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SiteWise 360° Capture',
              style: TextStyle(
                color: SiteWiseColors.ink,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Capture a commercial space one station at a time',
              style: TextStyle(color: SiteWiseColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The reference's `.info-panel` with a `.tab`-style action row.
class _LaunchCard extends StatelessWidget {
  const _LaunchCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: SiteWiseColors.surface,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: SiteWiseColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: SiteWiseColors.softBlue,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: SiteWiseColors.primary, size: 22),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: SiteWiseColors.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: SiteWiseColors.muted,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Icon(
                Icons.chevron_right,
                color: SiteWiseColors.muted,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The reference's `.callout` — what this build is and is not.
class _ShellNote extends StatelessWidget {
  const _ShellNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: SiteWiseColors.borderStrong),
    ),
    child: const Text(
      'Photographs and panoramas stay on this device. A finished panorama '
      'uploads to SiteWise only when the build is configured for it and you are '
      'signed in and authorised for the property. ARCore is used only by the two '
      'AR paths; the guided flow needs a camera and motion sensors.',
      style: TextStyle(color: Color(0xFF1E3A8A), fontSize: 12, height: 1.5),
    ),
  );
}
