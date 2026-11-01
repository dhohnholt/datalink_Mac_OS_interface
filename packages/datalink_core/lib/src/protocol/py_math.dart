/// Python's numeric behaviour, reproduced exactly.
///
/// The scoring code was written in Python and its results are stored, exported
/// and sent to a website, so "close enough" is not good enough: `round()`,
/// `sum()` of floats and the `statistics` module each do something specific.
/// Everything here is pinned to the original by golden files generated from it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

// ------------------------------------------------------------------ exact bits

/// `round(x, digits)` for a float: the decimal nearest to the *exact* binary
/// value, ties to even, then the float nearest that decimal.
double pyRound(double x, int digits) {
  if (x.isNaN || x.isInfinite) return x;
  if (x == 0) return x;
  final bits = (ByteData(8)..setFloat64(0, x)).getUint64(0);
  final negative = (bits >>> 63) & 1 == 1;
  final exponent = (bits >>> 52) & 0x7ff;
  final fraction = bits & 0xfffffffffffff;
  final mantissa = BigInt.from(exponent == 0 ? fraction : fraction | (1 << 52));
  final power = (exponent == 0 ? 1 : exponent) - 1075;

  final scale = BigInt.from(10).pow(digits);
  BigInt numerator = mantissa * scale;
  BigInt denominator = BigInt.one;
  if (power >= 0) {
    numerator = numerator << power;
  } else {
    denominator = BigInt.one << -power;
  }
  var quotient = numerator ~/ denominator;
  final remainder = numerator - quotient * denominator;
  final twice = remainder * BigInt.two;
  final cmp = twice.compareTo(denominator);
  if (cmp > 0 || (cmp == 0 && quotient.isOdd)) quotient += BigInt.one;

  if (quotient == BigInt.zero) return negative ? -0.0 : 0.0;
  final digitsText = quotient.toString().padLeft(digits + 1, '0');
  final whole = digitsText.substring(0, digitsText.length - digits);
  final fractionText = digitsText.substring(digitsText.length - digits);
  final text = digits == 0 ? whole : '$whole.$fractionText';
  final value = double.parse(text);
  return negative ? -value : value;
}

/// `round(x, digits)` for an int or a float: an int stays an int.
num pyRoundNum(num x, int digits) => x is int ? x : pyRound(x as double, digits);

/// `round(x)` with no digits: half to even, returning an int.
int pyRoundInt(double x) {
  final floor = x.floorToDouble();
  final diff = x - floor;
  if (diff < 0.5) return floor.toInt();
  if (diff > 0.5) return floor.toInt() + 1;
  final base = floor.toInt();
  return base.isEven ? base : base + 1;
}

/// `sum()` over floats. CPython 3.12 switched this to Neumaier-compensated
/// summation, which gives different last digits from a plain loop.
double pySumFloats(Iterable<double> values) {
  var total = 0.0;
  var compensation = 0.0;
  for (final x in values) {
    final t = total + x;
    if (total.abs() >= x.abs()) {
      compensation += (total - t) + x;
    } else {
      compensation += (x - t) + total;
    }
    total = t;
  }
  if (compensation != 0 && compensation.isFinite) total += compensation;
  return total;
}

// ---------------------------------------------------------- exact arithmetic

BigInt _isqrt(BigInt n) {
  if (n < BigInt.two) return n;
  var x = BigInt.one << ((n.bitLength + 1) ~/ 2);
  while (true) {
    final y = (x + n ~/ x) >> 1;
    if (y >= x) return x;
    x = y;
  }
}

/// `n / d` for two integers, correctly rounded, as Python's int true division.
double fractionToDouble(BigInt n, BigInt d) {
  if (n == BigInt.zero) return 0;
  final negative = n.isNegative != d.isNegative;
  final top = n.abs();
  final bottom = d.abs();
  final shift = math.max(0, 55 - (top.bitLength - bottom.bitLength)) + 1;
  final scaled = top << shift;
  var q = scaled ~/ bottom;
  final sticky = scaled - q * bottom != BigInt.zero;
  q = (q << 1) | (sticky ? BigInt.one : BigInt.zero);
  var exponent = -(shift + 1);
  final drop = q.bitLength - 53;
  if (drop > 0) {
    final rest = q & ((BigInt.one << drop) - BigInt.one);
    q >>= drop;
    final half = BigInt.one << (drop - 1);
    if (rest > half || (rest == half && q.isOdd)) q += BigInt.one;
    exponent += drop;
  }
  final value = q.toDouble() * math.pow(2.0, exponent);
  return negative ? -value : value;
}

/// An exact rational, for the `statistics` functions.
class _Frac {
  _Frac(BigInt n, BigInt d) {
    if (d.isNegative) {
      n = -n;
      d = -d;
    }
    final g = n.gcd(d);
    numerator = g == BigInt.zero ? n : n ~/ g;
    denominator = g == BigInt.zero ? d : d ~/ g;
  }

  late final BigInt numerator;
  late final BigInt denominator;

  /// `statistics._convert(value, int)`: an int when it is one, else a float.
  num toIntOrDouble() => denominator == BigInt.one
      ? numerator.toInt()
      : fractionToDouble(numerator, denominator);
}

/// `statistics.mean` of ints: an int when the mean is whole, else a float.
num pyMeanInts(List<int> data) {
  if (data.isEmpty) throw ArgumentError('mean requires at least one data point');
  final total = data.fold<BigInt>(BigInt.zero, (a, b) => a + BigInt.from(b));
  return _Frac(total, BigInt.from(data.length)).toIntOrDouble();
}

/// `statistics.median` of ints: the middle int, or a float for an even count.
num pyMedianInts(List<int> data) {
  if (data.isEmpty) throw ArgumentError('no median for empty data');
  final sorted = [...data]..sort();
  final n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

_Frac _sumSquaredDeviations(List<int> data) {
  final n = BigInt.from(data.length);
  final total = data.fold<BigInt>(BigInt.zero, (a, b) => a + BigInt.from(b));
  // Σ (x - total/n)² = (n·Σx² − total²) / n, exactly.
  final squares = data.fold<BigInt>(
    BigInt.zero,
    (a, b) => a + BigInt.from(b) * BigInt.from(b),
  );
  return _Frac(n * squares - total * total, n);
}

/// `statistics.variance` of ints.
num pyVarianceInts(List<int> data) {
  if (data.length < 2) {
    throw ArgumentError('variance requires at least two data points');
  }
  final ss = _sumSquaredDeviations(data);
  return _Frac(
    ss.numerator,
    ss.denominator * BigInt.from(data.length - 1),
  ).toIntOrDouble();
}

/// `statistics.pvariance` of ints: the exact sum of squared deviations over
/// n, an int when it divides exactly, as Python returns it.
num pyPVarianceInts(List<int> data) {
  if (data.isEmpty) {
    throw ArgumentError('pvariance requires at least one data point');
  }
  final ss = _sumSquaredDeviations(data);
  return _Frac(ss.numerator, ss.denominator * BigInt.from(data.length)).toIntOrDouble();
}

/// `statistics.stdev` of ints: the square root of the exact variance, rounded
/// once (Python's `_float_sqrt_of_frac`).
double pyStdevInts(List<int> data) {
  if (data.length < 2) {
    throw ArgumentError('stdev requires at least two data points');
  }
  final ss = _sumSquaredDeviations(data);
  final mss = _Frac(ss.numerator, ss.denominator * BigInt.from(data.length - 1));
  return _floatSqrtOfFrac(mss.numerator, mss.denominator);
}

double _floatSqrtOfFrac(BigInt n, BigInt m) {
  if (n <= BigInt.zero) return 0;
  const sqrtBitWidth = 2 * 53 + 3;
  final q = (n.bitLength - m.bitLength - sqrtBitWidth) ~/ 2;
  // Python floors a negative quotient toward -infinity; Dart's ~/ truncates.
  final diff = n.bitLength - m.bitLength - sqrtBitWidth;
  final floorQ = diff >= 0 ? q : -((-diff + 1) ~/ 2);
  BigInt numerator;
  BigInt denominator;
  if (floorQ >= 0) {
    numerator = _isqrtOfFracRto(n, m << (2 * floorQ)) << floorQ;
    denominator = BigInt.one;
  } else {
    numerator = _isqrtOfFracRto(n << (-2 * floorQ), m);
    denominator = BigInt.one << -floorQ;
  }
  return fractionToDouble(numerator, denominator);
}

/// Integer square root of n/m, rounded to odd, so the final rounding is right.
BigInt _isqrtOfFracRto(BigInt n, BigInt m) {
  final a = _isqrt(n ~/ m);
  final exact = a * a * m == n;
  return exact ? a : a | BigInt.one;
}
