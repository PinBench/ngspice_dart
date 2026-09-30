import 'dart:math' as math;

import 'package:ngspice_dart/ngspice_dart.dart';
import 'package:test/test.dart';

/// Helper: parse + run a deck and return the engine.
NgspiceEngine runDeck(List<String> lines) {
  final e = NgspiceEngine();
  e.loadCircuit(lines);
  e.run();
  return e;
}

void main() {
  group('SpiceValue parsing', () {
    test('engineering suffixes', () {
      expect(SpiceValue.tryParse('1k'), closeTo(1e3, 0));
      expect(SpiceValue.tryParse('1meg'), closeTo(1e6, 0));
      expect(SpiceValue.tryParse('2.2u'), closeTo(2.2e-6, 1e-18));
      expect(SpiceValue.tryParse('4.7n'), closeTo(4.7e-9, 1e-20));
      expect(SpiceValue.tryParse('1p'), closeTo(1e-12, 0));
      expect(SpiceValue.tryParse('5m'), closeTo(5e-3, 1e-15));
      expect(SpiceValue.tryParse('1e3'), closeTo(1e3, 0));
      expect(SpiceValue.tryParse('-3.3'), closeTo(-3.3, 1e-12));
    });

    test('units ignored after suffix', () {
      expect(SpiceValue.tryParse('10kohm'), closeTo(1e4, 0));
      expect(SpiceValue.tryParse('1uF'), closeTo(1e-6, 1e-18));
      expect(SpiceValue.tryParse('100Hz'), closeTo(100, 0));
    });

    test('non-numeric returns null', () {
      expect(SpiceValue.tryParse('abc'), isNull);
      expect(SpiceValue.tryParse(''), isNull);
    });
  });

  group('DC operating point', () {
    test('resistive voltage divider', () {
      final e = runDeck([
        'Divider',
        'V1 1 0 dc 10',
        'R1 1 2 1k',
        'R2 2 0 1k',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(2)')!.first, closeTo(5.0, 1e-9));
      expect(e.getVector('v(1)')!.first, closeTo(10.0, 1e-9));
    });

    test('series resistor current via source branch', () {
      final e = runDeck([
        'Series',
        'V1 1 0 dc 10',
        'R1 1 0 2k',
        '.op',
        '.end',
      ]);
      // Source branch current = -V/R (current flows + -> - inside source).
      final i = e.getVector('i(V1)')!.first;
      expect(i.abs(), closeTo(10.0 / 2000.0, 1e-9));
    });

    test('current source into resistor', () {
      final e = runDeck([
        'Inorton',
        'I1 0 1 dc 1m',
        'R1 1 0 1k',
        '.op',
        '.end',
      ]);
      // 1 mA into 1 kOhm -> 1 V.
      expect(e.getVector('v(1)')!.first, closeTo(1.0, 1e-9));
    });
  });

  group('Diode DC', () {
    test('forward biased diode drops ~0.6-0.75V', () {
      final e = runDeck([
        'Diode test',
        'V1 1 0 dc 5',
        'R1 1 2 1k',
        'D1 2 0 DMOD',
        '.model DMOD D(IS=1e-14 N=1)',
        '.op',
        '.end',
      ]);
      final vd = e.getVector('v(2)')!.first;
      expect(vd, greaterThan(0.5));
      expect(vd, lessThan(0.8));
      // Check current consistency: I ~= (5 - vd)/1k and matches Shockley.
      final iR = (5 - vd) / 1000.0;
      final iD = 1e-14 * (math.exp(vd / 0.025865) - 1);
      expect(iR, closeTo(iD, iR * 0.05));
    });
  });

  group('Transistor DC', () {
    test('an NPN in its active region multiplies the base current by BF', () {
      // Ib = (5 - Vbe) / 100k ~ 43 uA, so Ic ~ 4.3 mA and the 500 ohm
      // collector load drops ~2.15 V.
      final e = runDeck([
        'NPN active',
        'V1 1 0 dc 5',
        'RB 1 b 100k',
        'RC 1 c 500',
        'Q1 c b 0 QN',
        '.model QN NPN(IS=1e-14 BF=100)',
        '.op',
        '.end',
      ]);
      final vb = e.getVector('v(b)')!.first;
      final ib = (5 - vb) / 100e3;
      final ic = (5 - e.getVector('v(c)')!.first) / 500;
      expect(vb, inInclusiveRange(0.6, 0.8));
      expect(ic / ib, closeTo(100, 2));
    });

    test('an NPN switch saturates, its collector near the emitter', () {
      final e = runDeck([
        'NPN switch',
        'V1 1 0 dc 5',
        'RB 1 b 1k',
        'RC 1 c 220',
        'Q1 c b 0 QN',
        '.model QN NPN(IS=1e-14 BF=100)',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(c)')!.first, lessThan(0.3));
    });

    test('a PNP mirrors the NPN, and its model may follow it', () {
      final e = runDeck([
        'PNP active',
        'V1 1 0 dc 5',
        'Q1 c b 1 QP',
        'RB b 0 100k',
        'RC c 0 500',
        '.model QP PNP(IS=1e-14 BF=100)',
        '.op',
        '.end',
      ]);
      final vb = e.getVector('v(b)')!.first;
      final ib = vb / 100e3;
      final ic = e.getVector('v(c)')!.first / 500;
      expect(5 - vb, inInclusiveRange(0.6, 0.8));
      expect(ic / ib, closeTo(100, 2));
    });

    test('an NMOS in saturation follows the square law', () {
      // Vov = 4 - 2 = 2 V, so Id = KP/2 * Vov^2 = 2 mA and the drain sits at
      // 5 - 2 = 3 V, still above Vov: saturated, as assumed.
      final e = runDeck([
        'NMOS sat',
        'V1 1 0 dc 5',
        'VG g 0 dc 4',
        'RD 1 d 1k',
        'M1 d g 0 0 MN',
        '.model MN NMOS(LEVEL=1 VTO=2 KP=1m)',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(d)')!.first, closeTo(3.0, 1e-3));
    });

    test('an NMOS below threshold is off', () {
      final e = runDeck([
        'NMOS off',
        'V1 1 0 dc 5',
        'VG g 0 dc 1',
        'RD 1 d 1k',
        'M1 d g 0 0 MN',
        '.model MN NMOS(LEVEL=1 VTO=2 KP=1m)',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(d)')!.first, closeTo(5.0, 1e-3));
    });

    test('a PMOS conducts with its gate below the source', () {
      // Vgs = 1 - 5 = -4 V against VTO = -2 V: Id = 2 mA into a 1k load.
      final e = runDeck([
        'PMOS sat',
        'V1 1 0 dc 5',
        'VG g 0 dc 1',
        'M1 d g 1 1 MP',
        'RD d 0 1k',
        '.model MP PMOS(LEVEL=1 VTO=-2 KP=1m)',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(d)')!.first, closeTo(2.0, 1e-3));
    });

    test('W/L scales a MOSFET', () {
      final e = runDeck([
        'NMOS W/L',
        'V1 1 0 dc 5',
        'VG g 0 dc 3',
        'RD 1 d 1k',
        'M1 d g 0 0 MN W=4u L=2u',
        '.model MN NMOS(LEVEL=1 VTO=2 KP=1m)',
        '.op',
        '.end',
      ]);
      // Id = KP * (W/L) / 2 * 1^2 = 1 mA.
      expect(e.getVector('v(d)')!.first, closeTo(4.0, 1e-3));
    });
  });

  group('Transient RC charging', () {
    test('matches analytic exponential (UIC, cap starts at 0)', () {
      final e = runDeck([
        'RC',
        'V1 1 0 dc 5',
        'R1 1 2 1k',
        'C1 2 0 1u ic=0',
        '.tran 0.01m 5m uic',
        '.end',
      ]);
      final result = e.currentResult!;
      final time = result.sweep;
      final vc = result.realVector('v(2)')!;
      const tau = 1e-3; // R*C
      // Compare across the sweep against 5*(1-e^{-t/tau}).
      for (var i = 0; i < time.length; i += 10) {
        final analytic = 5.0 * (1 - math.exp(-time[i] / tau));
        expect(vc[i], closeTo(analytic, 0.02), reason: 'at t=${time[i]}');
      }
      // Source node stays at 5.
      expect(e.getVector('v(1)')!.first, closeTo(5.0, 1e-9));
    });
  });

  group('Transient RL', () {
    test('inductor current rises toward V/R', () {
      final e = runDeck([
        'RL',
        'V1 1 0 dc 1',
        'R1 1 2 10',
        'L1 2 0 1m ic=0',
        '.tran 0.005m 1m uic',
        '.end',
      ]);
      final result = e.currentResult!;
      final time = result.sweep;
      final il = result.realVector('i(L1)')!;
      const tau = 1e-4; // L/R = 1m/10
      const iFinal = 0.1; // V/R = 1/10
      for (var i = 0; i < time.length; i += 20) {
        final analytic = iFinal * (1 - math.exp(-time[i] / tau));
        expect(il[i].abs(), closeTo(analytic, 0.005),
            reason: 'at t=${time[i]}');
      }
    });
  });

  group('AC analysis', () {
    test('RC low-pass is -3dB at cutoff frequency', () {
      // fc = 1/(2*pi*R*C); R=1k, C=159.155nF -> fc ~ 1kHz.
      final e = runDeck([
        'RC LP',
        'V1 1 0 dc 0 ac 1',
        'R1 1 2 1k',
        'C1 2 0 159.155n',
        '.ac dec 20 10 100k',
        '.end',
      ]);
      final result = e.currentResult!;
      final freqs = result.sweep;
      final vout = result.complexVector('v(2)')!;

      // Find the point closest to 1 kHz.
      var best = 0;
      var bestErr = double.infinity;
      for (var i = 0; i < freqs.length; i++) {
        final err = (freqs[i] - 1000).abs();
        if (err < bestErr) {
          bestErr = err;
          best = i;
        }
      }
      final mag = vout[best].abs;
      expect(mag, closeTo(1 / math.sqrt2, 0.03),
          reason: 'magnitude at ~1kHz should be ~0.707');

      // Low frequency gain ~ 1, high frequency strongly attenuated.
      expect(vout.first.abs, closeTo(1.0, 0.02));
      expect(vout.last.abs, lessThan(0.05));
    });
  });

  group('Controlled sources', () {
    test('VCVS scales the controlling voltage', () {
      final e = runDeck([
        'VCVS',
        'V1 1 0 dc 2',
        'E1 out 0 1 0 3.0', // out = 3 * V(1)
        'R1 out 0 1k',
        '.op',
        '.end',
      ]);
      expect(e.getVector('v(out)')!.first, closeTo(6.0, 1e-9));
    });

    test('VCCS drives current through a load', () {
      final e = runDeck([
        'VCCS',
        'V1 1 0 dc 2',
        'G1 0 out 1 0 1m', // I(0->out) = 1m * V(1) = 2mA into out node
        'R1 out 0 1k',
        '.op',
        '.end',
      ]);
      // 2 mA through 1k -> 2 V.
      expect(e.getVector('v(out)')!.first, closeTo(2.0, 1e-9));
    });
  });

  group('DC sweep', () {
    test('sweeps source and tracks divider output', () {
      final e = runDeck([
        'Sweep',
        'V1 1 0 dc 0',
        'R1 1 2 1k',
        'R2 2 0 1k',
        '.dc V1 0 10 1',
        '.end',
      ]);
      final result = e.currentResult!;
      expect(result.sweep.length, equals(11));
      final vout = result.realVector('v(2)')!;
      for (var i = 0; i < result.sweep.length; i++) {
        expect(vout[i], closeTo(result.sweep[i] / 2, 1e-9));
      }
    });
  });
}
