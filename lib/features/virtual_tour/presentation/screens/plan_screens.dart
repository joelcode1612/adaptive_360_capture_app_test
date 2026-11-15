import 'package:flutter/material.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_availability.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/plan/commercial_plan.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/session/capture_state_machine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/capture_flow_engine.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/application/flow_state.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/capture_theme.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/presentation/widgets/flow_widgets.dart';

/// Screens 1–3: the introduction, the room details and the recommended plan.
///
/// Ported from `V[1]`, `V[2]` and `V[3]` of `360° Capture Prototype.html`. The
/// copy is kept close to the prototype's, including the two caveats it is
/// careful about: **the app does not measure the room**, and **the station count
/// is an estimate**. Both are shown as text rather than hidden in a tooltip,
/// because a user who thinks the count is measured will trust the plan for a
/// room it was never checked against.

/// Screen 1.
class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key, required this.controller});

  final dynamic controller;

  CaptureFlowEngine get engine => controller.engine;

  @override
  Widget build(BuildContext context) => FlowScaffold(
    onLight: true,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The prototype's hero is the 26-point sphere itself, empty, so the
        // count the flow keeps promising is on screen before the user answers
        // anything. A decorative icon was an invention of the first port.
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Center(
            child: SphereProgressMap(
              frames: plan26().frames,
              statuses: const <TargetStatus>[],
              size: 200,
              // The intro is one of the reference's white screens: the map's
              // white-alpha disc would vanish on it.
              onLight: true,
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Capture your space in 360°',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Capture your commercial space from guided directions to create a '
          '360° virtual tour. Each station is a set of views around one point, '
          'planned from your camera\'s field of view so the views overlap.',
          style: TextStyle(color: SiteWiseColors.muted, height: 1.45),
        ),
        const SizedBox(height: 12),
        const _Step(n: '1', text: 'Describe your room.'),
        const _Step(
          n: '2',
          text: 'Follow the on-screen targets and capture the required views.',
        ),
        const _Step(n: '3', text: 'Review the station and build the tour.'),
        _CapabilityBanner(controller: controller),
      ],
    ),
    footer: PrimaryButton(
      label: 'Set Up Capture',
      onPressed: () => controller.goTo(CaptureScreen.roomDetails),
    ),
  );
}

/// What this device can and cannot do, stated before the user starts.
///
/// Two separate facts, and the brief asks for both out loud rather than after
/// the first failed capture: the camera has to actually be available, and
/// guidance has to say whether it is ARCore tracking or the motion sensors. The
/// card is absent when everything is ready — a green "all systems go" panel
/// would be noise, and a warning that is always on is a warning nobody reads.
class _CapabilityBanner extends StatelessWidget {
  const _CapabilityBanner({required this.controller});

  final dynamic controller;

  CaptureFlowEngine get engine => controller.engine;

  @override
  Widget build(BuildContext context) {
    final fatal = engine.fatal;
    if (fatal != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NoteCard(
              tone: NoteTone.danger,
              icon: Icons.no_photography_outlined,
              child: Text(fatal),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: 'Try again',
                    onPressed: () async {
                      final still = await controller.retryCamera();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(still ?? 'Camera available.')),
                      );
                    },
                  ),
                ),
                if (controller.permissionPermanentlyDenied == true) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: SecondaryButton(
                      label: 'Open settings',
                      onPressed: () => controller.openPermissionSettings(),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    final tier = engine.arTier;
    if (tier.tier == ArTier.full) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: NoteCard(
        tone: NoteTone.warn,
        icon: Icons.explore_off,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tier.headline,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(tier.detail),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final String n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: SiteWiseColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SiteWiseColors.border),
      ),
      child: Row(
        children: [
          // `.stp b` — the number is a filled disc, not an icon.
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: CaptureColors.accent,
              shape: BoxShape.circle,
            ),
            child: Text(
              n,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

/// Screen 2.
class RoomDetailsScreen extends StatelessWidget {
  const RoomDetailsScreen({super.key, required this.controller});

  final dynamic controller;

  CaptureFlowEngine get engine => controller.engine;

  @override
  Widget build(BuildContext context) => FlowScaffold(
    onLight: true,
    title: 'Room details',
    onBack: controller.back,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('How would you describe this room?'),
        // `.cds` is a three-column grid, and `RoomSize` has exactly three
        // values, so the cards sit side by side as the reference draws them.
        Row(
          children: [
            for (final size in RoomSize.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: size == RoomSize.small ? 0 : 8,
                  ),
                  child: _RoomCard(
                    size: size,
                    selected: engine.roomSize == size,
                    onTap: () {
                      engine.roomSize = size;
                      controller.refresh();
                    },
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const _SectionTitle(
          'Are important parts of the room obstructed or separated?',
        ),
        for (final o in Obstruction.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _OptionCard(
              label: o.label,
              selected: engine.obstruction == o,
              onTap: () {
                engine.obstruction = o;
                controller.refresh();
              },
            ),
          ),
        const ProvisionalLabel(
          text:
              'Your answers choose a recommended plan. The app does not '
              'measure the room.',
        ),
      ],
    ),
    footer: PrimaryButton(
      label: 'Recommend Capture Plan',
      onPressed: () => controller.goTo(CaptureScreen.plan),
    ),
  );
}

/// The prototype's `h3` — 15 px semibold, with the reference's 14 px above the
/// group it heads and 8 px below it.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.size,
    required this.selected,
    required this.onTap,
  });

  final RoomSize size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // `.cd` / `.on`: 1.5 px translucent-white rule over a 5 % white fill, and the
    // selected card swaps both for the green the reference uses — `#4cc27f`, not
    // the `#2f9e5b` the buttons use.
    final rule = selected ? CaptureColors.primary : SiteWiseColors.border;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: rule, width: 1.5),
          borderRadius: BorderRadius.circular(12),
          color: selected ? SiteWiseColors.softBlue : SiteWiseColors.paper,
        ),
        child: Column(
          children: [
            // The prototype's little proportional rectangle, drawn at the
            // size the room claim is — that is the point of the picture.
            SizedBox(
              width: 56,
              height: 34,
              child: Center(
                child: Container(
                  width: size.iconWidth,
                  height: size.iconHeight,
                  decoration: BoxDecoration(
                    border: Border.all(color: rule),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Two lines of height reserved for every card, because the grid is
            // three equal cells and "Medium" would otherwise be shorter than
            // "Large / Open-plan".
            SizedBox(
              height: 34,
              child: Center(
                child: Text(
                  size.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, height: 1.25),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // `.op` / `.on` — the same rule and fill as `.cd`, at full width.
    final rule = selected ? CaptureColors.primary : SiteWiseColors.border;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: rule, width: 1.5),
          borderRadius: BorderRadius.circular(12),
          color: selected ? SiteWiseColors.softBlue : SiteWiseColors.paper,
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            if (selected)
              const Icon(
                Icons.check_circle,
                color: CaptureColors.okOnLight,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

/// Screen 3.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key, required this.controller});

  final dynamic controller;

  CaptureFlowEngine get engine => controller.engine;

  @override
  Widget build(BuildContext context) {
    final rec = engine.recommendation;
    return FlowScaffold(
      onLight: true,
      title: 'Capture plan',
      onBack: controller.back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ChipBadge(label: 'Recommended'),
          const SizedBox(height: 10),
          Text(
            rec.headline,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            rec.body,
            style: const TextStyle(color: SiteWiseColors.muted, height: 1.45),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _PlanOption(
                  label: 'One station',
                  selected: !rec.multiStation,
                  dots: 1,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PlanOption(
                  label: 'Multiple stations',
                  selected: rec.multiStation,
                  dots: 3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _CaptureGuideCard(),
          const SizedBox(height: 10),
          NoteCard(
            icon: Icons.help_outline,
            child: Text('Why: ${rec.reason(engine.obstruction)}'),
          ),
          NoteCard(
            icon: Icons.calculate_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Estimated stations: ${rec.estimate}'),
                const SizedBox(height: 4),
                const ProvisionalLabel(
                  text:
                      'An estimate from your answers, confirmed after the '
                      'capture review. Nothing here measured the room.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Where the frame count came from. The brief forbids reading the field
          // of view from a constant, so the number the plan was built from is
          // shown with its provenance rather than hidden.
          NoteCard(
            icon: Icons.straighten,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plan built for '
                  '${engine.planHfovDeg.toStringAsFixed(1)}°×'
                  '${engine.planVfovDeg.toStringAsFixed(1)}° '
                  '(${engine.settings.overlapH * 100 ~/ 1}% overlap)',
                ),
                const SizedBox(height: 4),
                ProvisionalLabel(
                  text: 'Field of view from ${engine.fovSource.label}.',
                ),
              ],
            ),
          ),
        ],
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Start Capture',
            onPressed: () => controller.goTo(CaptureScreen.stationSetup),
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            label: 'Change Room Details',
            onPressed: () => controller.goTo(CaptureScreen.roomDetails),
          ),
        ],
      ),
    );
  }
}

class _PlanOption extends StatelessWidget {
  const _PlanOption({
    required this.label,
    required this.selected,
    required this.dots,
  });

  final String label;
  final bool selected;
  final int dots;

  @override
  Widget build(BuildContext context) {
    // `.cmp>div` — the unselected card is the same surface at 65 % opacity,
    // which is how the reference marks the plan it did not recommend.
    final rule = selected ? CaptureColors.primary : SiteWiseColors.border;
    return Opacity(
      opacity: selected ? 1 : 0.65,
      child: Container(
        height: 96,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: rule, width: 1.5),
          borderRadius: BorderRadius.circular(12),
          color: selected ? SiteWiseColors.softBlue : SiteWiseColors.paper,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 6),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                spacing: 4,
                children: [
                  for (var i = 0; i < dots; i++)
                    Icon(
                      Icons.person_pin_circle,
                      size: 20,
                      color: selected ? CaptureColors.primary : rule,
                    ),
                ],
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? CaptureColors.primary : SiteWiseColors.slate,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// How to capture each direction, in the reference's `.guide-entry` style.
///
/// The plan tells the user *how many* views there are; this tells them *where
/// to point the phone*, which is the question a first-time user actually asks.
/// Five rows, one per band of the sphere — the same bands the progress map
/// breaks down, so the two screens cannot describe the plan differently.
class _CaptureGuideCard extends StatelessWidget {
  const _CaptureGuideCard();

  static const List<({IconData icon, String title, String detail})> _steps = [
    (
      icon: Icons.straighten,
      title: 'Middle ring',
      detail: 'Hold the phone level and turn a full circle.',
    ),
    (
      icon: Icons.keyboard_arrow_up,
      title: 'Upper ring',
      detail: 'Tilt up about 45° and turn a full circle again.',
    ),
    (
      icon: Icons.keyboard_arrow_down,
      title: 'Lower ring',
      detail: 'Tilt down about 45° and turn a full circle again.',
    ),
    (
      icon: Icons.arrow_upward,
      title: 'Ceiling',
      detail: 'Point the phone straight up and hold still.',
    ),
    (
      icon: Icons.arrow_downward,
      title: 'Floor',
      detail: 'Point the phone straight down and hold still.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 13, 14, 5),
    decoration: BoxDecoration(
      color: SiteWiseColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SiteWiseColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'How to capture',
          style: TextStyle(
            color: SiteWiseColors.ink,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'The phone takes each photo automatically once the marker is in the '
          'circle. You only have to turn and hold.',
          style: TextStyle(
            color: SiteWiseColors.muted,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        for (final step in _steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: SiteWiseColors.softBlue,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    step.icon,
                    size: 17,
                    color: SiteWiseColors.primary,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.title,
                        style: const TextStyle(
                          color: SiteWiseColors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        step.detail,
                        style: const TextStyle(
                          color: SiteWiseColors.muted,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
