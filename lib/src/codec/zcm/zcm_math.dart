// zcm: deterministic floating point functions.
//
// The LSTM of level 9 needs exp, tanh and the logistic function. The ones
// of dart:math call the platform's C library, whose last bit can differ
// between systems and versions, which would make a stream written on one
// machine fail to decode on another. These are built from +, -, *, / and
// comparisons only (IEEE 754 defines those exactly, with round to nearest
// even), so every platform computes the same bits. Accuracy is about
// 1e-15 relative, far more than the model needs; what matters is that it
// is the same everywhere.

import 'dart:typed_data';

const double _ln2Hi = 6.93147180369123816490e-01; // high bits of ln 2
const double _ln2Lo = 1.90821492927058770002e-10; // ln 2 - _ln2Hi
const double _invLn2 = 1.44269504088896338700e+00;

// 2^k for k in -1022..1023, built by exact doublings and halvings.
final Float64List _pow2 = () {
  final t = Float64List(2046);
  var v = 1.0;
  for (var k = 0; k <= 1023; k++) {
    t[k + 1022] = v;
    v = v * 2.0;
  }
  v = 1.0;
  for (var k = 0; k >= -1022; k--) {
    t[k + 1022] = v;
    v = v * 0.5;
  }
  return t;
}();

/// e^x, deterministic. Saturates to 0 below -700 and to 1e300 above 700.
double zexp(double x) {
  if (x > 700.0) return 1e300;
  if (x < -700.0) return 0.0;
  // x = k ln2 + r, |r| <= ln2 / 2 (Cody and Waite reduction).
  final kf = (x * _invLn2 + (x >= 0 ? 0.5 : -0.5));
  final k = kf.truncate();
  final r = (x - k * _ln2Hi) - k * _ln2Lo;
  // exp(r) by its Taylor series to degree 13 (|r| < 0.35: error < 1e-17).
  var s = 1.0 / 6227020800.0;
  s = s * r + 1.0 / 479001600.0;
  s = s * r + 1.0 / 39916800.0;
  s = s * r + 1.0 / 3628800.0;
  s = s * r + 1.0 / 362880.0;
  s = s * r + 1.0 / 40320.0;
  s = s * r + 1.0 / 5040.0;
  s = s * r + 1.0 / 720.0;
  s = s * r + 1.0 / 120.0;
  s = s * r + 1.0 / 24.0;
  s = s * r + 1.0 / 6.0;
  s = s * r + 0.5;
  s = s * r + 1.0;
  s = s * r + 1.0;
  return s * _pow2[k + 1022];
}

/// Logistic function 1 / (1 + e^-x), deterministic.
double zsigmoid(double x) => 1.0 / (1.0 + zexp(-x));

/// Hyperbolic tangent, deterministic.
double ztanh(double x) {
  if (x > 20.0) return 1.0;
  if (x < -20.0) return -1.0;
  if (x > -0.0001 && x < 0.0001) return x; // tanh x = x - x^3/3 ...
  final e = zexp(2.0 * x);
  return (e - 1.0) / (e + 1.0);
}

/// Square root. IEEE 754 requires sqrt to be correctly rounded, so the
/// platform's is exact; this wrapper only keeps the call sites explicit.
double zsqrt(double x) => _sqrt(x);

// Newton iterations from a power of two start: exact to the last bit is
// not needed here (the result is used identically everywhere), but it
// must not depend on the platform, so it avoids dart:math entirely.
double _sqrt(double x) {
  if (x <= 0.0) return 0.0;
  // Scale x into [1, 4) by powers of 4.
  var m = x;
  var scale = 1.0;
  while (m >= 4.0) {
    m *= 0.25;
    scale *= 2.0;
  }
  while (m < 1.0) {
    m *= 4.0;
    scale *= 0.5;
  }
  var r = 1.5;
  for (var i = 0; i < 6; i++) {
    r = 0.5 * (r + m / r);
  }
  return r * scale;
}
