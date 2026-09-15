import 'strack.dart';

/// IoU between two `(x1, y1, x2, y2)` boxes.
double _iou(List<double> a, List<double> b) {
  final interLeft = a[0] > b[0] ? a[0] : b[0];
  final interTop = a[1] > b[1] ? a[1] : b[1];
  final interRight = a[2] < b[2] ? a[2] : b[2];
  final interBottom = a[3] < b[3] ? a[3] : b[3];

  final interW = interRight > interLeft ? interRight - interLeft : 0.0;
  final interH = interBottom > interTop ? interBottom - interTop : 0.0;
  final interArea = interW * interH;

  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  final union = areaA + areaB - interArea;
  if (union <= 0) return 0.0;
  return interArea / union;
}

/// IoU-based cost matrix (`1 - IoU`) between two `STrack` lists. Mirrors
/// `matching.iou_distance` (the embedding/appearance variant is excluded —
/// this port has no Re-ID).
List<List<double>> iouDistance(List<STrack> aTracks, List<STrack> bTracks) {
  return [
    for (final a in aTracks)
      [for (final b in bTracks) 1.0 - _iou(a.tlbr, b.tlbr)],
  ];
}

/// Fuses detection confidence into an IoU cost matrix, mirroring
/// `matching.fuse_score`.
List<List<double>> fuseScore(
  List<List<double>> costMatrix,
  List<STrack> detections,
) {
  if (costMatrix.isEmpty) return costMatrix;
  return [
    for (var i = 0; i < costMatrix.length; i++)
      [
        for (var j = 0; j < costMatrix[i].length; j++)
          1.0 - ((1.0 - costMatrix[i][j]) * detections[j].score),
      ],
  ];
}

/// Result of solving an assignment problem: matched `[row, col]` index
/// pairs, plus the row/column indices left unmatched.
class AssignmentResult {
  const AssignmentResult(this.matches, this.unmatchedA, this.unmatchedB);

  final List<List<int>> matches;
  final List<int> unmatchedA;
  final List<int> unmatchedB;
}

/// Solves the assignment problem on [costMatrix], rejecting any pairing
/// whose cost exceeds [thresh].
///
/// The reference (`matching.linear_assignment`) uses `lap.lapjv` with
/// `cost_limit=thresh`, which treats an over-threshold pairing as
/// unassignable *during* the solve, not as a post-hoc filter applied to an
/// unconstrained optimum — those two can disagree, since forcing a pairing
/// below threshold can change which other pairs are optimal elsewhere. This
/// port reproduces the "during the solve" behavior by giving over-threshold
/// cells a large sentinel cost — steering the solver toward an explicit
/// "leave unmatched" option (the padding columns/rows added to square the
/// matrix, costed at `1.0`, which is worse than any real allowed cost but
/// far better than the sentinel) — rather than solving unconstrained and
/// filtering after.
///
/// [rows]/[cols] make the matrix's shape explicit and must be passed when
/// [costMatrix] might have zero rows: a `List<List<double>>` with zero rows
/// can't otherwise carry its intended column count (unlike the reference's
/// numpy array, which keeps a `(0, N)` shape), so an empty track pool
/// against N real detections would silently report zero unmatched
/// detections instead of N — dropping every detection instead of letting
/// them spawn new tracks.
AssignmentResult linearAssignment(
  List<List<double>> costMatrix,
  double thresh, {
  int? rows,
  int? cols,
}) {
  final nRows = rows ?? costMatrix.length;
  final nCols = cols ?? (costMatrix.isEmpty ? 0 : costMatrix[0].length);

  if (nRows == 0 || nCols == 0) {
    return AssignmentResult(
      [],
      List.generate(nRows, (i) => i),
      List.generate(nCols, (i) => i),
    );
  }

  const sentinel = 1e6;
  // The "leave unmatched" (padding) option must cost more than any real
  // allowed pairing (which is <= thresh by construction, since anything
  // over thresh is already routed to `sentinel` below) but far less than
  // `sentinel`, so the solver only falls back to it when no in-threshold
  // real pairing exists. Scaled off `thresh` rather than a bare `1.0` so
  // this stays correct if a caller ever passes a threshold above 1.0 (e.g.
  // wiring in Mahalanobis-distance gating, whose chi-square thresholds run
  // well past 1.0) instead of only the IoU-cost thresholds every current
  // call site in `bot_sort_tracker.dart` uses.
  final unmatchedCost = thresh + 1.0;

  final n = nRows > nCols ? nRows : nCols;
  final padded = List.generate(n, (i) {
    return List.generate(n, (j) {
      if (i < nRows && j < nCols) {
        final cost = costMatrix[i][j];
        return cost <= thresh ? cost : sentinel;
      }
      return unmatchedCost;
    });
  });

  final assignment = _hungarian(padded);

  final matches = <List<int>>[];
  final matchedRows = <int>{};
  final matchedCols = <int>{};
  for (final pair in assignment) {
    final i = pair[0], j = pair[1];
    if (i < nRows && j < nCols && costMatrix[i][j] <= thresh) {
      matches.add([i, j]);
      matchedRows.add(i);
      matchedCols.add(j);
    }
  }

  final unmatchedA = [
    for (var i = 0; i < nRows; i++)
      if (!matchedRows.contains(i)) i,
  ];
  final unmatchedB = [
    for (var j = 0; j < nCols; j++)
      if (!matchedCols.contains(j)) j,
  ];
  return AssignmentResult(matches, unmatchedA, unmatchedB);
}

/// Hungarian (Kuhn-Munkres) algorithm on a square cost matrix. Returns the
/// optimal `[row, col]` assignment for every row.
List<List<int>> _hungarian(List<List<double>> cost) {
  final n = cost.length;
  final work = [for (final row in cost) [...row]];

  for (var i = 0; i < n; i++) {
    final minVal = work[i].reduce((a, b) => a < b ? a : b);
    for (var j = 0; j < n; j++) {
      work[i][j] -= minVal;
    }
  }
  for (var j = 0; j < n; j++) {
    var minVal = double.infinity;
    for (var i = 0; i < n; i++) {
      if (work[i][j] < minVal) minVal = work[i][j];
    }
    for (var i = 0; i < n; i++) {
      work[i][j] -= minVal;
    }
  }

  final starred = List.generate(n, (_) => List.filled(n, 0));
  final rowCover = List.filled(n, false);
  final colCover = List.filled(n, false);

  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (work[i][j].abs() < 1e-9 && !rowCover[i] && !colCover[j]) {
        starred[i][j] = 1;
        rowCover[i] = true;
        colCover[j] = true;
      }
    }
  }
  for (var i = 0; i < n; i++) {
    rowCover[i] = false;
    colCover[i] = false;
  }
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (starred[i][j] == 1) colCover[j] = true;
    }
  }

  final maxIter = n * n * 10 + 10;
  var iter = 0;
  while (colCover.where((c) => c).length < n && iter++ < maxIter) {
    var ur = -1;
    var uc = -1;
    outer:
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (work[i][j].abs() < 1e-9 && !rowCover[i] && !colCover[j]) {
          ur = i;
          uc = j;
          break outer;
        }
      }
    }

    if (ur == -1) {
      var minVal = double.infinity;
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          if (!rowCover[i] && !colCover[j] && work[i][j] < minVal) {
            minVal = work[i][j];
          }
        }
      }
      if (minVal == double.infinity) break;
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          if (rowCover[i]) work[i][j] += minVal;
          if (!colCover[j]) work[i][j] -= minVal;
        }
      }
      continue;
    }

    starred[ur][uc] = 2;
    var sc = -1;
    for (var j = 0; j < n; j++) {
      if (starred[ur][j] == 1) {
        sc = j;
        break;
      }
    }

    if (sc != -1) {
      rowCover[ur] = true;
      colCover[sc] = false;
    } else {
      final path = [
        [ur, uc],
      ];
      while (true) {
        var sr = -1;
        for (var i = 0; i < n; i++) {
          if (starred[i][path.last[1]] == 1) {
            sr = i;
            break;
          }
        }
        if (sr == -1) break;
        path.add([sr, path.last[1]]);

        var pc = -1;
        for (var j = 0; j < n; j++) {
          if (starred[sr][j] == 2) {
            pc = j;
            break;
          }
        }
        if (pc == -1) break;
        path.add([sr, pc]);
      }

      for (final step in path) {
        if (starred[step[0]][step[1]] == 1) {
          starred[step[0]][step[1]] = 0;
        } else if (starred[step[0]][step[1]] == 2) {
          starred[step[0]][step[1]] = 1;
        }
      }

      for (var i = 0; i < n; i++) {
        rowCover[i] = false;
        colCover[i] = false;
        for (var j = 0; j < n; j++) {
          if (starred[i][j] == 2) starred[i][j] = 0;
        }
      }
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          if (starred[i][j] == 1) colCover[j] = true;
        }
      }
    }
  }

  final result = <List<int>>[];
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (starred[i][j] == 1) {
        result.add([i, j]);
        break;
      }
    }
  }
  return result;
}

/// Union of two track lists, deduplicated by track id — [a]'s entries win on
/// a collision. Mirrors `bot_sort.py`'s `joint_stracks`.
List<STrack> jointTracks(List<STrack> a, List<STrack> b) {
  final seen = <int>{};
  final result = <STrack>[];
  for (final t in a) {
    seen.add(t.trackId);
    result.add(t);
  }
  for (final t in b) {
    if (seen.add(t.trackId)) {
      result.add(t);
    }
  }
  return result;
}

/// Tracks in [a] whose id doesn't appear in [b]. Mirrors `sub_stracks`.
List<STrack> subTracks(List<STrack> a, List<STrack> b) {
  final idsToRemove = b.map((t) => t.trackId).toSet();
  return a.where((t) => !idsToRemove.contains(t.trackId)).toList();
}

/// Drops near-duplicate tracks between two lists (IoU > 0.85, i.e. cost <
/// 0.15) in favor of whichever track has been alive longer. Mirrors
/// `remove_duplicate_stracks`.
(List<STrack>, List<STrack>) removeDuplicateTracks(
  List<STrack> a,
  List<STrack> b,
) {
  final dupA = <int>{};
  final dupB = <int>{};
  for (var p = 0; p < a.length; p++) {
    for (var q = 0; q < b.length; q++) {
      final iou = _iou(a[p].tlbr, b[q].tlbr);
      if (1.0 - iou < 0.15) {
        final timeP = a[p].frameId - a[p].startFrame;
        final timeQ = b[q].frameId - b[q].startFrame;
        if (timeP > timeQ) {
          dupB.add(q);
        } else {
          dupA.add(p);
        }
      }
    }
  }
  final resA = [
    for (var i = 0; i < a.length; i++)
      if (!dupA.contains(i)) a[i],
  ];
  final resB = [
    for (var i = 0; i < b.length; i++)
      if (!dupB.contains(i)) b[i],
  ];
  return (resA, resB);
}
