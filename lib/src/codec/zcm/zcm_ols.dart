// zcm: recursive least squares prediction (paq8px OLS), for the audio
// and image models.
//
// After paq8px's OLS (Sebastian Lehmann, integrated by Marcio Pais): the
// covariance of the features and the target with exponential forgetting,
// solved by Cholesky factorization every few samples. Doubles with +, -,
// *, / and the correctly rounded square root in a fixed order, so every
// machine computes the same predictions.

import 'dart:typed_data';

import 'zcm_math.dart';

/// Recursive least squares predictor (paq8px OLS): [n] features, a solve
/// every [interval] updates, forgetting factor [lambda].
final class ZcmOls {
  final int n;
  final int interval;
  final double lambda;
  final double nu;
  final Float64List x;
  final Float64List w;
  final Float64List c; // covariance, lower triangle, n * n
  final Float64List b;
  final Float64List l; // Cholesky factor
  final Float64List t; // solve scratch
  int _k = 0;
  int _since = 0;

  ZcmOls(this.n, this.interval, this.lambda)
      : nu = 0.001,
        x = Float64List(n),
        w = Float64List(n),
        c = Float64List(n * n),
        b = Float64List(n),
        l = Float64List(n * n),
        t = Float64List(n);

  @pragma('vm:prefer-inline')
  void add(double v) {
    if (_k < n) x[_k++] = v;
  }

  double predict() {
    while (_k < n) {
      x[_k++] = 0.0;
    }
    _k = 0;
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += x[i] * w[i];
    }
    return s;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void update(double y) {
    final a = lambda;
    final be = 1.0 - lambda;
    for (var i = 0; i < n; i++) {
      final xb = x[i] * be;
      final r = i * n;
      for (var j = 0; j <= i; j++) {
        c[r + j] = a * c[r + j] + x[j] * xb;
      }
    }
    for (var i = 0; i < n; i++) {
      b[i] = a * b[i] + y * x[i] * be;
    }
    if (++_since >= interval) {
      _since = 0;
      if (_factor()) _solve();
    }
  }

  // Cholesky factorization of C + nu I.
  @pragma('vm:unsafe:no-bounds-checks')
  bool _factor() {
    for (var i = 0; i < n; i++) {
      final r = i * n;
      for (var j = 0; j <= i; j++) {
        var s = c[r + j];
        if (i == j) s += nu;
        final rj = j * n;
        for (var k = 0; k < j; k++) {
          s -= l[r + k] * l[rj + k];
        }
        if (i == j) {
          if (s <= 1e-10) return false;
          l[r + i] = zsqrt(s);
        } else {
          l[r + j] = s / l[rj + j];
        }
      }
    }
    return true;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _solve() {
    for (var i = 0; i < n; i++) {
      var s = b[i];
      final r = i * n;
      for (var k = 0; k < i; k++) {
        s -= l[r + k] * t[k];
      }
      t[i] = s / l[r + i];
    }
    for (var i = n - 1; i >= 0; i--) {
      var s = t[i];
      for (var k = i + 1; k < n; k++) {
        s -= l[k * n + i] * w[k];
      }
      w[i] = s / l[i * n + i];
    }
  }
}

