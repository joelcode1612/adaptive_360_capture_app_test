import 'package:flutter/material.dart';

/// The SiteWise palette, exactly as `SiteWise_360_Capture_Final_5_Views`
/// declares it in its `:root` block.
///
/// The reference is a blue-and-white product: white paper surfaces, a deep blue
/// primary, a slate ink, and a dark camera stage only where a live feed has to
/// be legible. The previous palette was a dark green console theme, which is why
/// the app did not read as SiteWise.
abstract final class SiteWiseColors {
  /// `--blue` — the primary action and the active selection.
  static const Color primary = Color(0xFF1D4ED8);

  /// `--blue-hover` — the pressed / hovered primary.
  static const Color primaryPressed = Color(0xFF1E40AF);

  /// `--soft` — a soft blue tint for selected rows and callouts.
  static const Color softBlue = Color(0xFFEFF6FF);

  /// `--bg` — the page behind the cards.
  static const Color canvas = Color(0xFFE8EEF6);

  /// `--paper` — the body surface inside a screen.
  static const Color paper = Color(0xFFF4F7FB);

  /// `--white` — cards, headers, footers.
  static const Color surface = Color(0xFFFFFFFF);

  /// `--ink` — headings and primary text.
  static const Color ink = Color(0xFF0B0F19);

  /// `--slate` — body text one step below [ink].
  static const Color slate = Color(0xFF1E293B);

  /// `--muted` — secondary text and captions.
  static const Color muted = Color(0xFF475569);

  /// `--line` — every border on a light surface.
  static const Color border = Color(0xFFDCE4EF);

  /// `#BFDBFE` — the stronger blue border the reference uses on selected cards
  /// and ghost buttons.
  static const Color borderStrong = Color(0xFFBFDBFE);

  /// `--teal` — a completed capture on a light surface.
  static const Color teal = Color(0xFF0D9488);

  /// `--amber` — a warning that has to be read on white.
  static const Color amberInk = Color(0xFF92400E);

  /// `--cam` — the camera stage. Dark, but blue-shifted so it belongs to the
  /// same family as [primary] rather than to a neutral console.
  static const Color cameraStage = Color(0xFF121A27);

  /// The text the reference puts on the camera stage (`#DCE7F6`).
  static const Color cameraInk = Color(0xFFDCE7F6);
}

/// The state palette, as Flutter constants.
///
/// The prototype's colours are named rather than inlined so that the
/// distinction it draws between states survives the port:
///
/// * [ok] — a target that passed validation.
/// * [warn] — something needs attention but is not a failure: a low-information
///   frame, a frame awaiting a retake, a paused capture.
/// * [danger] — a rejection.
///
/// **Two variants, because one colour cannot do both jobs.** [ok] is tuned for
/// the dark camera stage; [okOnLight] is the darker teal the same state needs on
/// a white footer. Contrast is a property of the pair, not of the hue, so the
/// light surfaces get their own tokens rather than a compromise that is legible
/// on neither.
abstract final class CaptureColors {
  /// The primary action. SiteWise blue.
  static const Color primary = SiteWiseColors.primary;

  /// The pressed / hovered primary.
  static const Color primaryPressed = SiteWiseColors.primaryPressed;

  /// A completed capture on the dark camera stage (`#34D399`).
  static const Color ok = Color(0xFF34D399);

  /// The same state on a white surface — teal 700, 4.8:1 on white.
  static const Color okOnLight = Color(0xFF0F766E);

  /// Amber on the dark stage (`#F2A93B`).
  static const Color warn = Color(0xFFF2A93B);

  /// Amber on white — 4.6:1, and the reference's own `--amber`.
  static const Color warnOnLight = SiteWiseColors.amberInk;

  /// Rejections on the dark stage.
  static const Color danger = Color(0xFFE5534B);

  /// Rejections on white — 5.9:1.
  static const Color dangerOnLight = Color(0xFFB91C1C);

  /// The primary action colour. Kept under its old name so every existing
  /// caller becomes SiteWise blue without a rename, but see [accentOnDark]:
  /// this value is a *fill*, and is too dark to read as text on the camera.
  static const Color accent = SiteWiseColors.primary;

  /// Blue legible **on** the dark stage, for icons and inline links.
  static const Color accentOnDark = Color(0xFF60A5FA);

  /// The camera chrome background (`#121A27`).
  static const Color cameraChrome = SiteWiseColors.cameraStage;

  /// The viewfinder's own background — the prototype's `.cam{background:#222}`.
  ///
  /// Deliberately *not* [cameraChrome]. The two states have to be told apart:
  /// `#222` is a viewfinder that is up and waiting for pixels, and `#121A27` is
  /// the chrome around it. When the feed cannot draw, it fills this grey and
  /// writes the reason on top, so "the camera is coming" never looks like the
  /// dead-black box that made the first device run unusable.
  static const Color viewfinder = Color(0xFF222222);

  /// Muted text on the dark chrome (`#AEB6BF`).
  static const Color mutedOnDark = Color(0xFFAEB6BF);

  /// Secondary text on a white surface (`--muted`).
  static const Color mutedOnLight = SiteWiseColors.muted;

  /// Primary text on a white surface (`--ink`).
  static const Color inkOnLight = SiteWiseColors.ink;

  /// A border on a white surface (`--line`).
  static const Color borderOnLight = SiteWiseColors.border;

  /// A card on a white surface — white with the reference's hairline.
  static const Color cardOnLight = SiteWiseColors.surface;

  /// The light body surface (`--paper`).
  static const Color paperOnLight = SiteWiseColors.paper;

  /// The prototype's `.orb` size, in logical pixels.
  static const double orbSize = 102;

  /// The aiming reticle's diameter, in logical pixels.
  ///
  /// Raised from 96 to 132 (+37 %). The 96 dp ring was hard to find on a busy
  /// camera image and harder to judge a centre against; the specification asks
  /// for 128–144, and 132 is the middle of that band. It is a *visual* token
  /// only — no tolerance, projection or capture gate reads it.
  static const double reticleSize = 132;

  /// An empty segment bar — the prototype's `.rng i` / `.fr i` (`#39424B`).
  static const Color trackOnDark = Color(0xFF39424B);

  /// An empty segment bar on white — `#DFE8F4`.
  static const Color trackOnLight = Color(0xFFDFE8F4);

  /// The header's right-hand slot — the prototype's `.hd span` (`#C3CAD2`).
  static const Color headerMuted = Color(0xFFC3CAD2);

  /// A bullet line inside a dark screen — the prototype's `.li` (`#D4DAE0`).
  static const Color bulletOnDark = Color(0xFFD4DAE0);

  /// The viewfinder's inset focus frame — `.frame`, `rgba(255,255,255,.6)`.
  static const Color viewfinderFrame = Color(0x99FFFFFF);

  /// A hairline border on the dark chrome — `.cd`, `.op`, `.on` unset
  /// (`rgba(255,255,255,.2)`).
  static const Color hairlineOnDark = Color(0x33FFFFFF);

  /// A hairline one step quieter — `.sl>div` (`rgba(255,255,255,.1)`).
  static const Color hairlineFaint = Color(0x1AFFFFFF);

  /// A chip outline — `.chs button` (`rgba(255,255,255,.25)`).
  static const Color hairlineChip = Color(0x40FFFFFF);

  /// A ghost button's border — `.bt.g` (`rgba(255,255,255,.35)`).
  static const Color ghostButtonBorder = Color(0x59FFFFFF);

  /// That border under `.bt:disabled{opacity:.45}` (0x59 × 0.45 ≈ 0x28). Material
  /// has no disabled outline colour of its own on `OutlinedButton.styleFrom`, so
  /// the scale is done here rather than left to the theme's grey.
  static const Color ghostButtonBorderDisabled = Color(0x28FFFFFF);

  /// A filled row or cell on the dark chrome — `.stp div` (`rgba(255,255,255,.06)`).
  static const Color cardOnDark = Color(0x0FFFFFFF);

  /// The `.dg` group behind a grid of cells (`rgba(255,255,255,.05)`).
  static const Color groupOnDark = Color(0x0DFFFFFF);

  /// The `.note` surface, one step brighter than [cardOnDark].
  static const Color noteOnDark = Color(0x12FFFFFF);

  /// The selected-card fill — `.on`, `rgba(29,78,216,.10)`.
  static const Color selectedFill = Color(0x1A1D4ED8);

  /// A text-only action on the dark chrome — a blue that clears 4.5:1 there.
  static const Color linkOnDark = Color(0xFF93C5FD);

  /// A sheet's surface, and the prototype's `.sht` (`#1A2025`).
  static const Color sheet = Color(0xFF1A2025);

  /// A light sheet — the SiteWise white surface.
  static const Color sheetOnLight = SiteWiseColors.surface;

  /// The scrim behind a sheet — `.shd` (`rgba(8,10,12,.78)`).
  static const Color scrim = Color(0xC7080A0C);

  /// The sphere map's disc fill and outline — `sph()`'s `rgba(255,255,255,.06)`
  /// over `rgba(255,255,255,.35)`.
  static const Color sphereFill = Color(0x0FFFFFFF);
  static const Color sphereOutline = Color(0x59FFFFFF);

  /// The sphere map on a white surface — `#EFF6FF` over `#BFDBFE`.
  static const Color sphereFillOnLight = SiteWiseColors.softBlue;
  static const Color sphereOutlineOnLight = SiteWiseColors.borderStrong;

  /// An un-fired target on the map — `sph()`'s pending stroke (`#9AA3AD`).
  static const Color pendingDot = Color(0xFF9AA3AD);

  /// The aiming ring before it is aligned. Brighter than [pendingDot] because
  /// this one has to be found against a live, moving camera image rather than
  /// on a flat map.
  static const Color reticleIdle = Color(0xFFE2E8F0);

  /// An un-fired target on a light surface — slate 400, readable on white.
  static const Color pendingDotOnLight = Color(0xFF94A3B8);

  /// The target cell grid's fill for an un-captured frame.
  static const Color frameCellEmpty = Color(0xFF39424B);

  /// A "simulated" / provisional badge.
  static const Color provisional = Color(0xFFF2A93B);

  /// A translucent white surface, as the prototype uses throughout.
  static Color surface(double opacity) =>
      Colors.white.withValues(alpha: opacity);

  /// The dark surface the camera chrome uses behind text.
  static Color chromeOverlay([double opacity = 0.8]) =>
      cameraChrome.withValues(alpha: opacity);

  /// A translucent ink surface for a chip that sits over a bright camera feed.
  static Color inkOverlay([double opacity = 0.72]) =>
      SiteWiseColors.ink.withValues(alpha: opacity);
}

/// Shared sizing so the screens agree with each other.
abstract final class CaptureMetrics {
  /// The viewfinder is 4:3 in portrait, matching the sensor the FOV model
  /// assumes. Kept here so the capture screen and the preview widget cannot
  /// drift apart.
  static const double viewfinderAspect = 3 / 4;

  /// The frame-cell grid: 13 columns × 2 rows, as the prototype draws it.
  static const int frameGridColumns = 13;

  static const double cornerRadius = 14;
  static const double smallRadius = 10;

  /// `.hd` — a 52 dp header row with a 32 dp round button in it.
  static const double headerHeight = 52;
  static const double headerIconSize = 32;

  /// The minimum interactive square the accessibility pass requires. The
  /// reference's own back button is 45 dp; this is the floor everything on the
  /// capture path now respects.
  static const double minTouchTarget = 48;

  /// `.frame` — the focus border's inset and corner.
  static const double viewfinderInset = 10;
  static const double viewfinderRadius = 16;

  /// `.mm` — the mini progress map, and the `.bn` banner that stops short of it.
  static const double miniMapSize = 88;
  static const double miniMapRadius = 18;
  static const double bannerRightInset = 108;

  /// `.bt` — 13 dp of padding around a 15 px semibold label.
  static const double buttonHeight = 48;

  /// The SiteWise footer button: 50 dp, as `.btn{min-height:50px}`.
  static const double primaryButtonHeight = 50;

  /// `.ip` — the instruction panel under the viewfinder.
  static const double instructionHeight = 128;

  /// The white footer's top corner radius, as the reference's native footer.
  static const double footerRadius = 20;

  /// The aiming reticle's responsive band. 132 dp nominal, never below 116 dp
  /// on a small phone and never above 148 dp on a tablet.
  static const double reticleMin = 116;
  static const double reticleMax = 148;

  /// The reticle diameter for a viewport, in logical pixels.
  ///
  /// 0.34 of the short side puts a 390 dp phone at 133 dp and a 320 dp phone at
  /// 116 dp — the specification's 128–144 band, clamped so a very small device
  /// still gets the larger circle without the ring colliding with the header.
  static double reticleFor(Size viewport) =>
      (viewport.shortestSide * 0.34).clamp(reticleMin, reticleMax);
}

/// The theme for the capture screens, whose scaffold is transparent so an AR
/// session's own camera surface can show through behind the Flutter view.
ThemeData captureCameraTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.transparent,
  colorScheme: _darkScheme,
);

/// The app's dark theme, used by the camera stages.
///
/// A viewfinder cannot be shown in a light theme, so the camera screens keep
/// this; the SiteWise white surfaces are applied per screen with
/// [captureLightTheme] rather than by flipping the whole app.
ThemeData captureAppTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: CaptureColors.cameraChrome,
  colorScheme: _darkScheme,
);

/// The SiteWise light theme for the white surfaces: footers, sheets and review.
///
/// It carries the reference's own tokens — `#FFFFFF` surfaces, `#0B0F19` ink,
/// `#475569` secondary text and `#DCE4EF` borders — so a light screen cannot
/// invent a fourth grey.
ThemeData captureLightTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  scaffoldBackgroundColor: SiteWiseColors.surface,
  colorScheme: _lightScheme,
  dividerColor: SiteWiseColors.border,
  textTheme: const TextTheme(
    titleLarge: TextStyle(
      color: SiteWiseColors.ink,
      fontSize: 20,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: TextStyle(
      color: SiteWiseColors.ink,
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: TextStyle(color: SiteWiseColors.muted, fontSize: 13),
    bodySmall: TextStyle(color: SiteWiseColors.muted, fontSize: 12),
  ),
);

const ColorScheme _darkScheme = ColorScheme.dark(
  primary: SiteWiseColors.primary,
  onPrimary: Colors.white,
  secondary: CaptureColors.ok,
  onSecondary: Colors.white,
  error: CaptureColors.danger,
  surface: CaptureColors.cameraChrome,
  onSurface: Colors.white,
  surfaceContainerHighest: CaptureColors.cardOnDark,
  onSurfaceVariant: CaptureColors.mutedOnDark,
  outline: CaptureColors.mutedOnDark,
  outlineVariant: CaptureColors.hairlineOnDark,
);

const ColorScheme _lightScheme = ColorScheme.light(
  primary: SiteWiseColors.primary,
  onPrimary: Colors.white,
  primaryContainer: SiteWiseColors.softBlue,
  onPrimaryContainer: SiteWiseColors.primaryPressed,
  secondary: SiteWiseColors.teal,
  onSecondary: Colors.white,
  error: CaptureColors.dangerOnLight,
  onError: Colors.white,
  surface: SiteWiseColors.surface,
  onSurface: SiteWiseColors.ink,
  surfaceContainerHighest: SiteWiseColors.paper,
  onSurfaceVariant: SiteWiseColors.muted,
  outline: SiteWiseColors.border,
  outlineVariant: SiteWiseColors.border,
);
