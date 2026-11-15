import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/plan_frame.dart';
// The projection and the status→role mapping used to be inlined in
// `_SphereMapPainter`; they now live here so the plain-`dart` suite can check
// the convention (looking down −Z, +Y up) and the colour role without a widget
// tree.
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/viz/sphere_map.dart';
// `TargetStatus` lives in the state machine, and `flow_state.dart` imports it
// for its own use without re-exporting it — so the status list a screen hands to
// the sphere map needs this import directly. (`flow_state.dart` is not imported
// here at all: the widgets below take plain values, not flow records.)
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';

/// Shared pieces of the capture screens.
///
/// The prototype repeats its chrome inline in every screen template; here it is
/// one widget each, so the nine screens differ only in their content. That also
/// keeps the "the app does not measure the room" and "the count is an estimate"
/// caveats in one place instead of nine.

/// The chrome for the non-camera screens: `.sc`, which is a header, a scrolling
/// body (`.bd2`) and a footer that sticks to the bottom (`.ft`).
///
/// There is no `AppBar` here on purpose. The prototype's header is 52 dp of the
/// screen's own dark background with a 15 px title in it — not a 64 dp tinted bar
/// with a 22 px title — and that difference is most of what makes the port look
/// like the reference rather than like Material.
class FlowScaffold extends StatelessWidget {
  const FlowScaffold({
    super.key,
    this.title,
    required this.body,
    this.trailing,
    this.footer,
    this.onBack,
    this.onLight = false,
  });

  /// Omit it for a screen the reference gives no header — `V[1]` is the only
  /// one, and it starts on the sphere map instead.
  final String? title;
  final Widget body;

  /// Shown at the right of the header — the prototype's `hd()` second slot.
  final Widget? trailing;

  final Widget? footer;
  final VoidCallback? onBack;

  /// Whether this screen is one of the reference's **white** screens.
  ///
  /// The design reference puts the introduction, the plan, progress and review
  /// on white paper with ink text, and keeps only the camera stages dark. This
  /// flag is that distinction, so a screen opts in rather than each one
  /// re-deriving a background and a text colour.
  final bool onLight;

  @override
  Widget build(BuildContext context) {
    final background = onLight
        ? SiteWiseColors.surface
        : CaptureColors.cameraChrome;
    final textStyle = onLight
        ? const TextStyle(
            color: SiteWiseColors.slate,
            fontSize: 14,
            height: 1.45,
          )
        : const TextStyle(color: Colors.white, fontSize: 14, height: 1.45);
    return Theme(
      // Material's own defaults have to follow, or a `TextButton` or a divider
      // inside a light screen keeps the dark theme's ink.
      data: onLight ? captureLightTheme() : captureAppTheme(),
      child: Scaffold(
        backgroundColor: background,
        body: SafeArea(
          child: Column(
            children: [
              if (title != null || onBack != null)
                FlowHeader(
                  title: title ?? '',
                  trailing: trailing,
                  onBack: onBack,
                  onLight: onLight,
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                  child: DefaultTextStyle.merge(style: textStyle, child: body),
                ),
              ),
              if (footer != null)
                Container(
                  width: double.infinity,
                  color: onLight ? SiteWiseColors.surface : null,
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [footer!],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The prototype's `.hd`: a 52 dp row holding a round back button, the title,
/// and a small muted line on the right.
///
/// The capture screen uses it directly rather than through [FlowScaffold],
/// because there the body is a viewfinder instead of a scrolling column.
class FlowHeader extends StatelessWidget {
  const FlowHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onBack,
    this.onLight = false,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;

  /// White header with ink text and a bordered back button, as the reference's
  /// `.head` on a light screen.
  final bool onLight;

  @override
  Widget build(BuildContext context) => Container(
    decoration: onLight
        ? const BoxDecoration(
            color: SiteWiseColors.surface,
            border: Border(bottom: BorderSide(color: SiteWiseColors.border)),
          )
        : null,
    child: SizedBox(
      height: CaptureMetrics.headerHeight,
      child: Padding(
        // `.hd{padding:8px 14px 0}` — the 8 dp is above the text, not around
        // it, so the title sits on the header's bottom edge and the body starts
        // immediately under it.
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Row(
          children: [
            if (onBack != null) ...[
              _HeaderBackButton(onPressed: onBack!, onLight: onLight),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: onLight ? SiteWiseColors.ink : Colors.white,
                  // 16 dp, not 15: this is the only title on a capture screen.
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
}

/// The prototype's `.ib` — a round back button.
///
/// The reference draws it at 45 dp; this floors it at the 48 dp minimum touch
/// target, because the header's back action is the one control a user reaches
/// for while walking and holding a phone in the other hand.
class _HeaderBackButton extends StatelessWidget {
  const _HeaderBackButton({required this.onPressed, this.onLight = false});

  final VoidCallback onPressed;
  final bool onLight;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Back',
    child: SizedBox.square(
      dimension: CaptureMetrics.minTouchTarget,
      child: IconButton(
        onPressed: onPressed,
        tooltip: 'Back',
        icon: Icon(
          Icons.chevron_left,
          size: 24,
          color: onLight ? SiteWiseColors.ink : Colors.white,
        ),
        style: IconButton.styleFrom(
          backgroundColor: onLight
              ? SiteWiseColors.paper
              : CaptureColors.surface(0.12),
          side: onLight ? const BorderSide(color: SiteWiseColors.border) : null,
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
        ),
      ),
    ),
  );
}

/// The dark chrome the camera screens use.
class CameraScaffold extends StatelessWidget {
  const CameraScaffold({super.key, required this.body, this.footer});

  final Widget body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => Theme(
    // The app's default theme is the SiteWise light one, so a dark camera
    // screen has to opt back into the dark scheme — otherwise a control that
    // takes its colour from the theme (a bare `TextButton`, a divider) would
    // render ink-on-ink over the feed.
    data: captureAppTheme(),
    child: Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: body),
            ?footer,
          ],
        ),
      ),
    ),
  );
}

/// The prototype's `.bt` — SiteWise's primary action.
///
/// Blue `#1D4ED8`, white label, 50 dp tall and a 13 dp corner, exactly as the
/// design reference draws it. The previous green fill was the most visible
/// difference between this app and the SiteWise screens.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: FilledButton(
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        backgroundColor: CaptureColors.primary,
        foregroundColor: Colors.white,
        // `.btn:hover{background:var(--blue-hover)}` — the pressed primary.
        overlayColor: CaptureColors.primaryPressed,
        // `.bt:disabled{opacity:.45}` — the label stays legible, which a
        // theme-default disabled grey does not.
        disabledBackgroundColor: CaptureColors.primary.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.75),
        minimumSize: const Size.fromHeight(CaptureMetrics.primaryButtonHeight),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    ),
  );
}

/// The prototype's `.bt.g` — the quieter alternative next to a primary action.
///
/// Two variants, because the same control sits on two surfaces: white ghost
/// chrome over the camera, and the reference's blue-on-white ghost on a light
/// footer. [onLight] picks the second.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.onLight = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool onLight;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: OutlinedButton(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: onLight ? CaptureColors.primary : Colors.white,
        // `.bt:disabled{opacity:.45}`, applied to the label. The outline cannot
        // take the same value through `styleFrom`, so it is scaled by hand.
        disabledForegroundColor: onLight
            ? CaptureColors.primary.withValues(alpha: 0.45)
            : Colors.white.withValues(alpha: 0.45),
        backgroundColor: onLight ? Colors.white : Colors.transparent,
        side: BorderSide(
          color: onLight
              ? SiteWiseColors.borderStrong
              : (enabled
                    ? CaptureColors.ghostButtonBorder
                    : CaptureColors.ghostButtonBorderDisabled),
        ),
        minimumSize: const Size.fromHeight(CaptureMetrics.primaryButtonHeight),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    ),
  );
}

/// The prototype's `.lk` — a text-only action.
class LinkButton extends StatelessWidget {
  const LinkButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: CaptureColors.linkOnDark,
      textStyle: const TextStyle(fontSize: 13),
    ),
    child: Text(label),
  );
}

/// The prototype's `.note` — an aside the user should read.
///
/// A neutral note is the prototype's exactly: translucent white, 12 dp corner, no
/// border. The toned variants keep that surface and add the coloured border,
/// because brief §5 requires green success and amber warning to be visible, and
/// the reference marks those states with colour rather than with a note style.
class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.child,
    this.tone = NoteTone.neutral,
    this.icon,
  });

  final Widget child;
  final NoteTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    // One widget, two surfaces. The note follows the scaffold it is in rather
    // than taking a flag at every one of its dozen call sites, so a screen that
    // moves to white cannot leave an invisible white-on-white card behind.
    final light = Theme.of(context).brightness == Brightness.light;
    final color = switch (tone) {
      NoteTone.neutral =>
        light ? SiteWiseColors.muted : CaptureColors.mutedOnDark,
      NoteTone.warn => light ? CaptureColors.warnOnLight : CaptureColors.warn,
      NoteTone.ok => light ? CaptureColors.okOnLight : CaptureColors.ok,
      NoteTone.danger =>
        light ? CaptureColors.dangerOnLight : CaptureColors.danger,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: light
            ? (tone == NoteTone.neutral
                  ? SiteWiseColors.paper
                  : SiteWiseColors.softBlue)
            : CaptureColors.noteOnDark,
        border: Border.all(
          color: light
              ? (tone == NoteTone.neutral
                    ? SiteWiseColors.border
                    : color.withValues(alpha: 0.4))
              : (tone == NoteTone.neutral
                    ? Colors.transparent
                    : color.withValues(alpha: 0.55)),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: light ? SiteWiseColors.slate : Colors.white,
                fontSize: 13,
                height: 1.45,
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

enum NoteTone { neutral, warn, ok, danger }

/// The prototype's `.chip` — a solid status badge — or its dashed `.sim` badge
/// in [outlined] form.
///
/// The two carry opposite claims and the reference styles them differently:
/// `.chip` is a fact about the plan, `.sim` is a disclaimer about what is *not*
/// real. Keeping both on this widget means a screen cannot invent a third look
/// for "this is simulated".
class ChipBadge extends StatelessWidget {
  const ChipBadge({
    super.key,
    required this.label,
    this.color,
    this.outlined = false,
  });

  final String label;
  final Color? color;

  /// `.sim` — amber outline on the dark chrome, for the "no real stitching" and
  /// "provisional" disclaimers. Flutter draws no dashed border, so the outline
  /// approximation stands in for the reference's `border:1px dashed`.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final c = color ?? CaptureColors.accent;
    if (outlined) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: c),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          // Amber is far brighter than the greens it sits beside, so the label
          // goes dark on amber rather than the reference's white-on-amber, which
          // measures 2.1:1.
          color: c == CaptureColors.warn
              ? CaptureColors.cameraChrome
              : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A label that says the number beside it is not a measurement.
///
/// Used wherever the flow shows a field of view, an occlusion percentage or a
/// station count. The brief forbids presenting a provisional or estimated value
/// as if it were measured, and one widget is the way to make that hard to forget.
class ProvisionalLabel extends StatelessWidget {
  const ProvisionalLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final color = light ? CaptureColors.warnOnLight : CaptureColors.provisional;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.info_outline, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: color, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// A station marker on the floor plan.
class PlanStation {
  const PlanStation({
    required this.x,
    required this.y,
    required this.label,
    this.accepted = false,
    this.current = false,
  });

  /// Normalised 0…1 inside the room rectangle.
  final double x;
  final double y;
  final String label;
  final bool accepted;
  final bool current;
}

/// The floor-plan diagram from screens 4 and 8.
///
/// A plan view with the room rectangle, the stations already placed, and — on
/// screen 4 — the suggested first position or the area the next station will
/// cover. It is a diagram, not a map: the prototype says so and so does the
/// caption, because the app never measures the room and the positions are
/// normalised guesses.
class FloorPlanDiagram extends StatelessWidget {
  const FloorPlanDiagram({
    super.key,
    required this.stations,
    this.highlight,
    this.onTap,
    this.height = 200,
  });

  final List<PlanStation> stations;

  /// The area the *next* station will cover, when the user is choosing one.
  final Rect? highlight;

  /// Reports a normalised tap inside the room rectangle.
  final void Function(double x, double y)? onTap;

  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = height;
        // The room is drawn 4:3, matching `RoomBox`'s nominal proportions.
        final roomW = w * 0.92;
        final roomH = math.min(h, roomW * 0.66);
        final left = (w - roomW) / 2;
        final top = (h - roomH) / 2;

        return SizedBox(
          height: h,
          child: GestureDetector(
            onTapDown: onTap == null
                ? null
                : (d) {
                    final nx = ((d.localPosition.dx - left) / roomW).clamp(
                      0.0,
                      1.0,
                    );
                    final ny = ((d.localPosition.dy - top) / roomH).clamp(
                      0.0,
                      1.0,
                    );
                    onTap!(nx, ny);
                  },
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: roomW,
                  height: roomH,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CaptureColors.cardOnDark,
                      border: Border.all(color: CaptureColors.hairlineOnDark),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                if (highlight != null)
                  Positioned(
                    left: left + highlight!.left * roomW,
                    top: top + highlight!.top * roomH,
                    width: highlight!.width * roomW,
                    height: highlight!.height * roomH,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: CaptureColors.accent.withValues(alpha: 0.16),
                        border: Border.all(color: CaptureColors.accent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                for (final s in stations)
                  Positioned(
                    left: left + s.x * roomW - 14,
                    top: top + s.y * roomH - 14,
                    child: _StationDot(station: s),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StationDot extends StatelessWidget {
  const _StationDot({required this.station});

  final PlanStation station;

  @override
  Widget build(BuildContext context) {
    final color = station.accepted
        ? CaptureColors.ok
        : station.current
        ? CaptureColors.accent
        : CaptureColors.mutedOnDark;
    return Tooltip(
      message: station.label,
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(
          station.accepted ? Icons.check : Icons.person_pin_circle,
          size: 14,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// The spherical progress map from screen 6.
///
/// The reference draws its progress on a sphere of 4000 equal-area samples.
/// This is the same idea at a size a phone can render: the sample cloud as a
/// faint disc, the plan's 27 target directions on top, coloured by status, and
/// the current target ringed.
///
/// **It is a progress map, not the AR target.** The prototype is explicit about
/// that and the caption repeats it, because a user who mistakes this for the
/// aiming view will hold the phone at the map.
class SphereProgressMap extends StatelessWidget {
  const SphereProgressMap({
    super.key,
    required this.frames,
    required this.statuses,
    this.currentIndex,
    this.size = 240,
    this.showSamples = true,
    this.onLight = false,
  });

  final List<PlanFrame> frames;
  final List<TargetStatus> statuses;
  final int? currentIndex;
  final double size;
  final bool showSamples;

  /// Whether the map sits on a white screen instead of the camera stage.
  final bool onLight;

  @override
  Widget build(BuildContext context) {
    final done = statuses
        .where((TargetStatus s) => s == TargetStatus.ok)
        .length;
    // One sentence, not thirty dots: the map is a picture of a count, and a
    // screen reader announcing each node would be noise rather than progress.
    final label =
        'Capture progress map: $done of ${frames.length} photographs saved'
        '${currentIndex == null ? '' : '. Current view ${currentIndex! + 1}'}';
    return Semantics(
      label: label,
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _SphereMapPainter(
            frames: frames,
            statuses: statuses,
            currentIndex: currentIndex,
            samples: showSamples ? fibonacciSamples(1200) : null,
            outline: onLight
                ? CaptureColors.sphereOutlineOnLight
                : CaptureColors.sphereOutline,
            fill: onLight
                ? CaptureColors.sphereFillOnLight
                : CaptureColors.sphereFill,
            pending: onLight
                ? CaptureColors.pendingDotOnLight
                : CaptureColors.pendingDot,
          ),
        ),
      ),
    );
  }
}

class _SphereMapPainter extends CustomPainter {
  _SphereMapPainter({
    required this.frames,
    required this.statuses,
    required this.currentIndex,
    required this.samples,
    required this.outline,
    required this.fill,
    required this.pending,
  });

  final List<PlanFrame> frames;
  final List<TargetStatus> statuses;
  final int? currentIndex;
  final SphereSamples? samples;
  final Color outline;
  final Color fill;
  final Color pending;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;

    canvas.drawCircle(c, r, Paint()..color = fill);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = outline,
    );

    // Orthographic projection, looking down -Z: the +Y axis is up on screen and
    // +X is to the right — the same convention the plan uses. Delegated to
    // [SphereProjection] so the geometry and the status→role mapping are checked
    // by the plain-`dart` suite rather than only on a device.
    Offset project(Vec3 v) {
      final (cx, cy) = SphereProjection.toCanvas(
        SphereProjection.project(v),
        c.dx,
        c.dy,
        r,
      );
      return Offset(cx, cy);
    }

    if (samples != null) {
      final p = Paint()..color = outline.withValues(alpha: 0.35);
      for (var i = 0; i < samples!.n; i++) {
        canvas.drawCircle(project(samples!.at(i)), 0.9, p);
      }
    }

    for (var i = 0; i < frames.length; i++) {
      final status = i < statuses.length ? statuses[i] : TargetStatus.pending;
      final role = sphereDotRole(status);
      final color = switch (role) {
        SphereDotRole.ok => CaptureColors.ok,
        SphereDotRole.warn => CaptureColors.warn,
        SphereDotRole.neutral => pending,
      };
      final o = project(frames[i].direction);
      final radius = currentIndex == i ? 7.0 : 4.5;
      // A pending target is a ring, not a dot — `sph()` draws it with
      // `fill:none`, and an unfired plan should read as empty rather than as a
      // dim version of a captured frame.
      canvas.drawCircle(
        o,
        radius,
        Paint()
          ..color = color
          ..style = (role == SphereDotRole.neutral
              ? PaintingStyle.stroke
              : PaintingStyle.fill)
          ..strokeWidth = 1.5,
      );
      if (currentIndex == i) {
        canvas.drawCircle(
          o,
          radius + 3.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SphereMapPainter old) =>
      old.frames != frames ||
      old.statuses != statuses ||
      old.currentIndex != currentIndex;
}

/// A labelled progress bar, used by the map sheet's ring breakdown.
class RingProgressRow extends StatelessWidget {
  const RingProgressRow({
    super.key,
    required this.label,
    required this.done,
    required this.total,
    this.color = CaptureColors.ok,
    this.onLight = false,
  });

  final String label;
  final int done;
  final int total;
  final Color color;
  final bool onLight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 8,
              backgroundColor: onLight
                  ? CaptureColors.trackOnLight
                  : CaptureColors.trackOnDark,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('$done/$total', style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}
