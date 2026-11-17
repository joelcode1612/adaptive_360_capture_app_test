/// Graph-cut seam finding for the equirectangular canvas.
///
/// ## Why a cut and not a search
///
/// Ownership has to be decided for ~2.1 M pixels, each of which has exactly two
/// candidate frames. That is a **binary, submodular** energy, so the globally
/// optimal labelling is a minimum s-t cut — no heuristic can do better on the
/// same cost function. The earlier row-wise search could only move a boundary
/// one pixel at a time along a row; it cannot, for example, route a seam *around*
/// a wardrobe that straddles the weight contour, which is exactly the case that
/// leaves a duplicated object.
///
/// ## Why the cut runs on a reduced grid
///
/// A full-resolution grid is 2.1 M nodes and ~8.4 M edges. Dinic's algorithm
/// needs the residual graph resident, which at that size is roughly 130 MB of
/// typed arrays — more than the rest of the accumulator combined, on a device
/// that already downgrades resolution to stay inside its budget.
///
/// The cut therefore runs on a [scale]-reduced grid (default 4×: 512×256 = 131 k
/// nodes, ~17 MB) and the labelling is upsampled. That loses at most `scale`
/// pixels of boundary precision, which the full-resolution polish in
/// `seam_blend.refineSeams` then recovers: the coarse cut decides *which side*
/// of an object the seam passes, the polish decides the exact pixel. Splitting
/// the work this way is what makes a global optimum affordable here.
///
/// ## Cost function
///
/// * **t-link (data).** Assigning a pixel to a frame costs `−ln(w)`, the same
///   sampling preference the projection weights already encode. A frame that
///   sees the direction obliquely or near its edge is expensive to use.
/// * **n-link (seam).** Cutting between two neighbours costs
///   `kSeamCostWeight · meanChannelDelta / 255`, the disagreement the two frames
///   show there. The cut is therefore cheap exactly where the photographs agree,
///   which is what makes a seam invisible.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Default reduction factor for the cut grid.
const int kSeamCutScale = 4;

/// Above this many coarse nodes the cut is skipped and the caller keeps the
/// weight-derived labelling. 512×256 is comfortably inside this bound; a 4096
/// panorama at scale 4 is 1024×512 = 524 k nodes, which still fits.
const int kSeamCutMaxNodes = 600000;

/// Approximate resident bytes the cut graph needs for a canvas of this size.
///
/// Reported in `coverage_report.json` so a memory regression is visible without
/// a profiler. Per directed edge entry: Float64 capacity (8) + Int32 target (4)
/// + Int32 next (4). Per node: four Int32 arrays (head, level, iter, queue).
int seamCutGraphBytes(int width, int height, {int scale = kSeamCutScale}) {
  final gw = (width + scale - 1) ~/ scale;
  final gh = (height + scale - 1) ~/ scale;
  final cells = gw * gh;
  if (cells > kSeamCutMaxNodes) return 0;
  final edges = cells * 12 + 16;
  return edges * 16 + (cells + 2) * 16;
}

/// Runs the min-cut and returns a full-resolution ownership label map.
///
/// `0` means "the best contributor owns this pixel", `1` means "the second
/// contributor does". Pixels with no second contributor are `0`.
///
/// Returns `null` when the graph would exceed [kSeamCutMaxNodes]; the caller then
/// keeps its weight-derived labels rather than failing the stitch.
Uint8List? findSeamLabels({
  required int width,
  required int height,
  required Uint8List bestColour,
  required Uint8List secondColour,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required double minWeight,
  required double seamCostWeight,
  int scale = kSeamCutScale,
}) {
  if (width < 2 || height < 2) return null;
  final gw = (width + scale - 1) ~/ scale;
  final gh = (height + scale - 1) ~/ scale;
  final cells = gw * gh;
  if (cells > kSeamCutMaxNodes) return null;

  final nodeCount = cells + 2;
  final s = cells;
  final t = cells + 1;

  // ── Per-cell data costs, averaged over the pixels the cell covers. ─────
  final dataBest = Float64List(cells);
  final dataSecond = Float64List(cells);
  final deltaSum = Float64List(cells);
  final active = Uint8List(cells);

  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      final cell = gy * gw + gx;
      var count = 0;
      var activeCount = 0;
      var bestCost = 0.0;
      var secondCost = 0.0;
      var delta = 0.0;
      final y1 = math.min(height, (gy + 1) * scale);
      final x1 = math.min(width, (gx + 1) * scale);
      for (var y = gy * scale; y < y1; y++) {
        final row = y * width;
        for (var x = gx * scale; x < x1; x++) {
          final i = row + x;
          count++;
          if (secondWeight[i] <= minWeight || secondFrame[i] < 0) {
            // No alternative here: this pixel is pinned to its best frame, so
            // the cell must not be cuttable on its behalf.
            continue;
          }
          activeCount++;
          bestCost += -math.log(bestWeight[i] + 1e-6);
          secondCost += -math.log(secondWeight[i] + 1e-6);
          delta += _delta(bestColour, secondColour, i);
        }
      }
      if (count == 0) continue;
      if (activeCount == 0) {
        // Fully pinned: make the sink option impossible.
        dataBest[cell] = 0;
        dataSecond[cell] = double.infinity;
        active[cell] = 0;
        continue;
      }
      dataBest[cell] = bestCost / activeCount;
      dataSecond[cell] = secondCost / activeCount;
      deltaSum[cell] = delta / activeCount;
      active[cell] = 1;
    }
  }

  // ── Build the graph. ──────────────────────────────────────────────────
  //
  // Typed arrays, preallocated. Growable `List<double>` boxes every element —
  // roughly 24 bytes each instead of 8 — which at ~1.5 M directed edges would
  // cost more than the whole accumulator. The bound is exact: two t-links per
  // cell plus at most four n-link entries (two neighbours, each added in both
  // directions).
  final maxEdges = cells * 12 + 16;
  final edgeCapacity = Float64List(maxEdges);
  final edgeTo = Int32List(maxEdges);
  final edgeNext = Int32List(maxEdges);
  var edgeCount = 0;
  final head = Int32List(nodeCount)..fillRange(0, nodeCount, -1);

  void addEdge(int u, int v, double capacity) {
    edgeTo[edgeCount] = v;
    edgeCapacity[edgeCount] = capacity;
    edgeNext[edgeCount] = head[u];
    head[u] = edgeCount++;

    edgeTo[edgeCount] = u;
    edgeCapacity[edgeCount] = 0;
    edgeNext[edgeCount] = head[v];
    head[v] = edgeCount++;
  }

  for (var gy = 0; gy < gh; gy++) {
    for (var gx = 0; gx < gw; gx++) {
      final cell = gy * gw + gx;
      if (active[cell] == 0) {
        // Pinned to "best": a huge source-side cost for choosing "second".
        addEdge(s, cell, 1e9);
        addEdge(cell, t, 0);
        continue;
      }
      // Cutting source→cell means the cell lands on the sink side ("second"),
      // so it must pay what "second" costs.
      addEdge(s, cell, dataSecond[cell]);
      addEdge(cell, t, dataBest[cell]);

      // Right and down neighbours, capacity = seam cost if the two differ.
      if (gx + 1 < gw) {
        final other = cell + 1;
        if (active[other] == 1) {
          final cap =
              seamCostWeight * (deltaSum[cell] + deltaSum[other]) / 2 / 255.0;
          addEdge(cell, other, cap);
          addEdge(other, cell, cap);
        }
      }
      if (gy + 1 < gh) {
        final other = cell + gw;
        if (active[other] == 1) {
          final cap =
              seamCostWeight * (deltaSum[cell] + deltaSum[other]) / 2 / 255.0;
          addEdge(cell, other, cap);
          addEdge(other, cell, cap);
        }
      }
    }
  }

  _dinic(nodeCount, s, t, head, edgeTo, edgeNext, edgeCapacity);

  // ── Reachable set = source side = "best". ─────────────────────────────
  final level = Int32List(nodeCount)..fillRange(0, nodeCount, -1);
  final queue = Int32List(nodeCount);
  var qh = 0;
  var qt = 0;
  level[s] = 0;
  queue[qt++] = s;
  while (qh < qt) {
    final u = queue[qh++];
    for (var e = head[u]; e != -1; e = edgeNext[e]) {
      if (edgeCapacity[e] <= 1e-12) continue;
      final v = edgeTo[e];
      if (level[v] != -1) continue;
      level[v] = level[u] + 1;
      queue[qt++] = v;
    }
  }

  // ── Upsample: every pixel in the cell takes the cell's label. ─────────
  final labels = Uint8List(width * height);
  for (var gy = 0; gy < gh; gy++) {
    final y1 = math.min(height, (gy + 1) * scale);
    for (var gx = 0; gx < gw; gx++) {
      final cell = gy * gw + gx;
      // Unreachable from the source → sink side → "second" (1).
      final label = level[cell] == -1 ? 1 : 0;
      if (label == 0) continue;
      final x1 = math.min(width, (gx + 1) * scale);
      for (var y = gy * scale; y < y1; y++) {
        final row = y * width;
        for (var x = gx * scale; x < x1; x++) {
          final i = row + x;
          // Never hand a pixel to a frame that does not cover it.
          if (secondWeight[i] <= minWeight || secondFrame[i] < 0) continue;
          labels[i] = 1;
        }
      }
    }
  }
  return labels;
}

/// Dinic's max-flow. Mutates `capacity` (the residual graph).
void _dinic(
  int nodeCount,
  int s,
  int t,
  Int32List head,
  Int32List to,
  Int32List next,
  Float64List capacity,
) {
  final level = Int32List(nodeCount);
  final iter = Int32List(nodeCount);
  final queue = Int32List(nodeCount);
  const inf = 1e18;

  bool bfs() {
    level.fillRange(0, nodeCount, -1);
    var qh = 0;
    var qt = 0;
    level[s] = 0;
    queue[qt++] = s;
    while (qh < qt) {
      final u = queue[qh++];
      for (var e = head[u]; e != -1; e = next[e]) {
        if (capacity[e] <= 1e-12) continue;
        final v = to[e];
        if (level[v] != -1) continue;
        level[v] = level[u] + 1;
        queue[qt++] = v;
      }
    }
    return level[t] != -1;
  }

  double dfs(int u, double pushed) {
    if (u == t) return pushed;
    for (var e = iter[u]; e != -1; e = next[e]) {
      iter[u] = e;
      if (capacity[e] <= 1e-12) continue;
      final v = to[e];
      if (level[v] != level[u] + 1) continue;
      final flow = dfs(v, math.min(pushed, capacity[e]));
      if (flow > 1e-12) {
        capacity[e] -= flow;
        capacity[e ^ 1] += flow;
        return flow;
      }
    }
    iter[u] = -1;
    return 0;
  }

  while (bfs()) {
    iter.setRange(0, nodeCount, head);
    while (true) {
      final flow = dfs(s, inf);
      if (flow <= 1e-12) break;
    }
  }
}

double _delta(Uint8List a, Uint8List b, int i) =>
    ((a[i * 3] - b[i * 3]).abs() +
        (a[i * 3 + 1] - b[i * 3 + 1]).abs() +
        (a[i * 3 + 2] - b[i * 3 + 2]).abs()) /
    3.0;
