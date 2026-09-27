// TLSH digests and distances against the reference implementation
// (github.com/trendmicro/tlsh 4.x, its tlsh_unittest tool: the vectors
// below were made with it from the same inputs).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/util/tlsh.dart';

import 'zx_test_util.dart';

void main() {
  final t2 = textBytes(10000, 4);
  for (var i = 0; i < t2.length; i += 97) {
    t2[i] = 0x41;
  }
  final inputs = <String, Uint8List>{
    'r1': lcgBytes(4096, 1),
    'r2': lcgBytes(50, 2),
    'r3': lcgBytes(1 << 20, 3),
    't1': textBytes(10000, 4),
    't2': t2,
  };
  const expected = {
    'r1':
        'T1D0815CFA132DF6A19448F05091F94BAC3B28DAF29AC93D2E5410496059A4383C2FE559',
    'r2':
        'T17B900288855905444D6255A3654D1025CA1108841A630551A25909B615853080510888',
    'r3':
        'T1B825332DE02790F835768ACF8ABD98BC8784E16C239D0FC85766B1A0563D501EC99F77',
    't1':
        'T11C22F8B17E34137110964181F99A6E9080BEF0552B0344F7983DC3A7769ECBBE27A7DA',
    't2':
        'T1BD2207B17E34137110864181E99A6E9084BEF0952B0344F7983DC3A7769ECBBD37A7DA',
  };

  test('digests match the reference tool', () {
    for (final e in expected.entries) {
      expect(Tlsh.of(inputs[e.key]!), e.value, reason: e.key);
    }
  });

  test('updates in pieces give the same digest', () {
    final d = inputs['r3']!;
    final t = Tlsh();
    for (var i = 0; i < d.length; i += 777) {
      t.update(d, i, i + 777 < d.length ? i + 777 : d.length);
    }
    expect(t.digest(), expected['r3']);
  });

  test('distances match the reference tool', () {
    expect(tlshDistance(expected['t1']!, expected['t2']!), 9);
    expect(tlshDistance(expected['r1']!, expected['t1']!), 419);
    expect(tlshDistance(expected['t1']!, expected['t1']!), 0);
    expect(tlshDistance('junk', expected['t1']!), isNull);
  });

  test('no digest for small or uniform inputs', () {
    expect(Tlsh.of(lcgBytes(49, 2)), isNull);
    expect(Tlsh.of(Uint8List(1000)), isNull);
    expect(Tlsh.of(Uint8List.fromList(List.filled(100, 0x78))), isNull);
  });

  test('the text form parses back', () {
    final p = TlshDigest.parse(expected['t1']!)!;
    expect(p.code.length, 32);
    expect(TlshDigest.parse(expected['t1']!.substring(2)), isNotNull);
    expect(TlshDigest.parse('T1XYZ'), isNull);
  });
}
