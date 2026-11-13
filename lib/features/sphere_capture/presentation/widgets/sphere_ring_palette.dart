import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

/// Ring colours from the reference sphere diagram.
///
/// These are used by the schematic views (the start-screen diagram and the
/// top-right progress map), not by the camera overlay: there, green means
/// "captured" and white means "pending", and recolouring by ring would make
/// those two states ambiguous.
const Color kSphereZenithColor = Color(0xFFF2B233);
const Color kSphereUpperColor = Color(0xFF6FB3E0);
const Color kSphereMiddleColor = Color(0xFF1F6FB2);
const Color kSphereLowerColor = Color(0xFF6FB3E0);
const Color kSphereNadirColor = Color(0xFFF2B233);

/// The reference diagram's colour for [spec]'s ring.
Color sphereRingColor(SphereTargetSpec spec) {
  if (spec.isZenith) return kSphereZenithColor;
  if (spec.isNadir) return kSphereNadirColor;
  if (spec.pitchDeg > 0) return kSphereUpperColor;
  if (spec.pitchDeg < 0) return kSphereLowerColor;
  return kSphereMiddleColor;
}
