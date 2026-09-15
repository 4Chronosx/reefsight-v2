/// Small dense-matrix helpers for the Kalman filter's fixed-size (8x8, or
/// 4x4/2x2 for position-only gating) state. Hand-rolled rather than pulled
/// from a package: BoT-SORT's state is always this small, so a
/// general-purpose linear algebra dependency isn't worth the size for the
/// handful of operations actually needed here.
library;

typedef Matrix = List<List<double>>;

Matrix zeros(int rows, int cols) =>
    List.generate(rows, (_) => List.filled(cols, 0.0));

Matrix identity(int n) {
  final m = zeros(n, n);
  for (var i = 0; i < n; i++) {
    m[i][i] = 1.0;
  }
  return m;
}

Matrix diag(List<double> values) {
  final n = values.length;
  final m = zeros(n, n);
  for (var i = 0; i < n; i++) {
    m[i][i] = values[i];
  }
  return m;
}

Matrix transpose(Matrix a) {
  final rows = a.length;
  final cols = a.isEmpty ? 0 : a[0].length;
  final t = zeros(cols, rows);
  for (var i = 0; i < rows; i++) {
    for (var j = 0; j < cols; j++) {
      t[j][i] = a[i][j];
    }
  }
  return t;
}

Matrix matMul(Matrix a, Matrix b) {
  final rows = a.length;
  final inner = b.length;
  final cols = b.isEmpty ? 0 : b[0].length;
  final result = zeros(rows, cols);
  for (var i = 0; i < rows; i++) {
    for (var k = 0; k < inner; k++) {
      final aik = a[i][k];
      if (aik == 0) continue;
      for (var j = 0; j < cols; j++) {
        result[i][j] += aik * b[k][j];
      }
    }
  }
  return result;
}

List<double> matVec(Matrix a, List<double> v) {
  final rows = a.length;
  final result = List<double>.filled(rows, 0.0);
  for (var i = 0; i < rows; i++) {
    var sum = 0.0;
    for (var j = 0; j < v.length; j++) {
      sum += a[i][j] * v[j];
    }
    result[i] = sum;
  }
  return result;
}

Matrix matAdd(Matrix a, Matrix b) {
  final rows = a.length;
  final cols = a.isEmpty ? 0 : a[0].length;
  final result = zeros(rows, cols);
  for (var i = 0; i < rows; i++) {
    for (var j = 0; j < cols; j++) {
      result[i][j] = a[i][j] + b[i][j];
    }
  }
  return result;
}

Matrix matSub(Matrix a, Matrix b) {
  final rows = a.length;
  final cols = a.isEmpty ? 0 : a[0].length;
  final result = zeros(rows, cols);
  for (var i = 0; i < rows; i++) {
    for (var j = 0; j < cols; j++) {
      result[i][j] = a[i][j] - b[i][j];
    }
  }
  return result;
}

List<double> vecSub(List<double> a, List<double> b) =>
    List.generate(a.length, (i) => a[i] - b[i]);

List<double> vecAdd(List<double> a, List<double> b) =>
    List.generate(a.length, (i) => a[i] + b[i]);

/// Inverts a square matrix via Gauss-Jordan elimination with partial
/// pivoting. BoT-SORT's reference uses a Cholesky factorization plus a
/// triangular solve for the same symmetric positive-definite systems
/// (`update` and `gating_distance`); a direct inverse is algebraically
/// equivalent for those well-conditioned, small (<=4x4) matrices and simpler
/// to verify by hand.
Matrix invert(Matrix a) {
  final n = a.length;
  final aug = List.generate(
    n,
    (i) => [
      ...a[i],
      for (var j = 0; j < n; j++) (i == j ? 1.0 : 0.0),
    ],
  );

  for (var col = 0; col < n; col++) {
    var pivotRow = col;
    var maxAbs = aug[col][col].abs();
    for (var r = col + 1; r < n; r++) {
      if (aug[r][col].abs() > maxAbs) {
        maxAbs = aug[r][col].abs();
        pivotRow = r;
      }
    }
    if (pivotRow != col) {
      final tmp = aug[col];
      aug[col] = aug[pivotRow];
      aug[pivotRow] = tmp;
    }
    final pivot = aug[col][col];
    for (var j = 0; j < 2 * n; j++) {
      aug[col][j] /= pivot;
    }
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final factor = aug[r][col];
      if (factor == 0) continue;
      for (var j = 0; j < 2 * n; j++) {
        aug[r][j] -= factor * aug[col][j];
      }
    }
  }

  return List.generate(n, (i) => aug[i].sublist(n, 2 * n));
}
