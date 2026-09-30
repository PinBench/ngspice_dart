import 'dart:math' as math;

import '../numeric/complex.dart';
import 'device.dart';

/// One term of a linearised device current: `g * (V(plus) - V(minus))`.
class _Term {
  final int plus;
  final int minus;
  final double g;
  const _Term(this.plus, this.minus, this.g);
}

/// Stamps a current flowing [from] -> [to] through a device, linearised as
/// `ieq + sum(g * (V(plus) - V(minus)))` — a constant source in parallel with
/// voltage-controlled current sources, which is all a Newton step needs.
void _stampCurrent(
    StampContext ctx, int from, int to, double ieq, List<_Term> terms) {
  for (final t in terms) {
    ctx.mna.stampMatrix(from, t.plus, t.g);
    ctx.mna.stampMatrix(from, t.minus, -t.g);
    ctx.mna.stampMatrix(to, t.plus, -t.g);
    ctx.mna.stampMatrix(to, t.minus, t.g);
  }
  ctx.mna.stampCurrentSource(from, to, ieq);
}

void _stampAcCurrent(AcStampContext ctx, int from, int to, List<_Term> terms) {
  for (final t in terms) {
    final g = Complex.real(t.g);
    ctx.mna.stampMatrix(from, t.plus, g);
    ctx.mna.stampMatrix(from, t.minus, -g);
    ctx.mna.stampMatrix(to, t.plus, -g);
    ctx.mna.stampMatrix(to, t.minus, g);
  }
}

double _thermalVoltage(double temp) => 1.380649e-23 * temp / 1.602176634e-19;

/// Parameters for a bipolar transistor (the DC core of the SPICE `.model
/// NPN`/`PNP` card: the Ebers-Moll transport model). Gummel-Poon refinements —
/// Early voltage, high injection, base resistance — are accepted on the card
/// and ignored.
class BjtModel {
  final bool pnp;
  final double isat; // transport saturation current (IS)
  final double bf; // forward beta (BF)
  final double br; // reverse beta (BR)
  final double nf; // forward emission coefficient (NF)
  final double nr; // reverse emission coefficient (NR)
  final double temp; // temperature in Kelvin

  const BjtModel({
    this.pnp = false,
    this.isat = 1e-16,
    this.bf = 100,
    this.br = 1,
    this.nf = 1,
    this.nr = 1,
    this.temp = 300.15,
  });

  double get vt => _thermalVoltage(temp);
}

/// Bipolar junction transistor (collector [c], base [b], emitter [e]) in the
/// Ebers-Moll transport form, solved with Newton-Raphson. Both junctions get
/// the diode's `pnjlim` limiting and a `gmin` shunt.
class Bjt extends Device {
  final int c;
  final int b;
  final int e;
  final BjtModel model;
  final double gmin;

  double _vbePrev = 0.0;
  double _vbcPrev = 0.0;
  bool _started = false;

  // Small-signal terms at the operating point, reused by AC analysis.
  List<_Term> _ce = const [];
  List<_Term> _be = const [];
  List<_Term> _bc = const [];

  Bjt(super.name, this.c, this.b, this.e, this.model, {this.gmin = 1e-12});

  @override
  bool get isNonlinear => true;

  @override
  void stamp(StampContext ctx) {
    // Everything below is written for an NPN; a PNP is the same device with
    // every junction voltage and current negated.
    final p = model.pnp ? -1.0 : 1.0;
    final vt = model.vt;
    final nfVt = model.nf * vt;
    final nrVt = model.nr * vt;

    final vbeRaw = p * (ctx.v(b) - ctx.v(e));
    final vbcRaw = p * (ctx.v(b) - ctx.v(c));
    var vbe = vbeRaw;
    var vbc = vbcRaw;
    if (_started) {
      vbe = _limitJunction(vbe, _vbePrev, nfVt);
      vbc = _limitJunction(vbc, _vbcPrev, nrVt);
      if ((vbe - vbeRaw).abs() > 1e-12 || (vbc - vbcRaw).abs() > 1e-12) {
        ctx.limited = true;
      }
    } else {
      _started = true;
      ctx.limited = true; // first evaluation is never a converged point
    }
    _vbePrev = vbe;
    _vbcPrev = vbc;

    final ef = math.exp(vbe / nfVt);
    final er = math.exp(vbc / nrVt);
    final iF = model.isat * (ef - 1);
    final iR = model.isat * (er - 1);
    final gF = model.isat * ef / nfVt;
    final gR = model.isat * er / nrVt;

    // Transport current, collector to emitter.
    _ce = [_Term(b, e, gF), _Term(b, c, -gR)];
    _stampCurrent(ctx, c, e, p * (iF - iR - gF * vbe + gR * vbc), _ce);

    // Base-emitter and base-collector diode currents.
    final gBe = gF / model.bf + gmin;
    _be = [_Term(b, e, gBe)];
    _stampCurrent(ctx, b, e, p * (iF / model.bf + gmin * vbe - gBe * vbe), _be);

    final gBc = gR / model.br + gmin;
    _bc = [_Term(b, c, gBc)];
    _stampCurrent(ctx, b, c, p * (iR / model.br + gmin * vbc - gBc * vbc), _bc);
  }

  @override
  void stampAc(AcStampContext ctx) {
    _stampAcCurrent(ctx, c, e, _ce);
    _stampAcCurrent(ctx, b, e, _be);
    _stampAcCurrent(ctx, b, c, _bc);
  }

  /// `pnjlim`, as the diode uses: bounds the per-iteration change in a
  /// junction voltage so `exp` cannot overflow.
  double _limitJunction(double vnew, double vold, double nvt) {
    final vcrit = nvt * math.log(nvt / (math.sqrt2 * model.isat));
    if (vnew > vcrit && (vnew - vold).abs() > 2 * nvt) {
      if (vold > 0) {
        final arg = 1 + (vnew - vold) / nvt;
        vnew = arg > 0 ? vold + nvt * math.log(arg) : vcrit;
      } else {
        vnew = vnew > 0 ? nvt * math.log(vnew / nvt) : vnew;
      }
    }
    return vnew;
  }

  @override
  void reset() {
    _vbePrev = 0.0;
    _vbcPrev = 0.0;
    _started = false;
    _ce = _be = _bc = const [];
  }
}

/// Parameters for an enhancement MOSFET (the SPICE level-1 `.model
/// NMOS`/`PMOS` card: the Shichman-Hodges square law).
class MosfetModel {
  final bool pmos;
  final double vto; // threshold voltage (VTO); negative for a PMOS
  final double kp; // transconductance parameter (KP)
  final double lambda; // channel-length modulation (LAMBDA)

  const MosfetModel({
    this.pmos = false,
    this.vto = 0.0,
    this.kp = 2e-5,
    this.lambda = 0.0,
  });
}

/// MOSFET (drain [d], gate [g], source [s]; the body terminal is accepted and
/// assumed tied to the source) with the level-1 square law. Drain and source
/// swap roles when the drain is the lower terminal, as in a real device.
class Mosfet extends Device {
  final int d;
  final int g;
  final int s;
  final MosfetModel model;

  /// Width / length, from the instance line (`W=`, `L=`).
  final double aspect;
  final double gmin;

  double _vgsPrev = 0.0;
  bool _started = false;
  List<_Term> _ds = const [];

  Mosfet(super.name, this.d, this.g, this.s, this.model,
      {this.aspect = 1.0, this.gmin = 1e-12});

  @override
  bool get isNonlinear => true;

  @override
  void stamp(StampContext ctx) {
    final p = model.pmos ? -1.0 : 1.0;
    final vt = p * model.vto;
    final beta = model.kp * aspect;

    // Forward when the drain is the higher terminal (for an NMOS); otherwise
    // the source acts as the drain and the current runs the other way.
    final forward = p * (ctx.v(d) - ctx.v(s)) >= 0;
    final hi = forward ? d : s; // the terminal acting as drain
    final lo = forward ? s : d; // the terminal acting as source

    final vgsRaw = p * (ctx.v(g) - ctx.v(lo));
    final vds = p * (ctx.v(hi) - ctx.v(lo));
    var vgs = vgsRaw;
    if (_started) {
      // A gentle `fetlim`: no more than half a volt of gate swing per step.
      const step = 0.5;
      if ((vgs - _vgsPrev).abs() > step) {
        vgs = _vgsPrev + step * (vgs - _vgsPrev).sign;
        ctx.limited = true;
      }
    } else {
      _started = true;
      ctx.limited = true;
    }
    _vgsPrev = vgs;

    final vov = vgs - vt;
    double id = 0, gm = 0, gds = 0;
    if (vov > 0) {
      final clm = 1 + model.lambda * vds;
      if (vds < vov) {
        final core = vov * vds - vds * vds / 2;
        id = beta * core * clm;
        gm = beta * vds * clm;
        gds = beta * (vov - vds) * clm + beta * core * model.lambda;
      } else {
        id = beta / 2 * vov * vov * clm;
        gm = beta * vov * clm;
        gds = beta / 2 * vov * vov * model.lambda;
      }
    }

    // Current from `hi` to `lo`, then gmin across the channel.
    _ds = [_Term(g, lo, gm), _Term(hi, lo, gds)];
    _stampCurrent(ctx, hi, lo, p * (id - gm * vgs - gds * vds), _ds);
    ctx.mna.stampConductance(d, s, gmin);
  }

  @override
  void stampAc(AcStampContext ctx) {
    final forward = _ds.isEmpty || _ds.last.plus == d;
    _stampAcCurrent(ctx, forward ? d : s, forward ? s : d, _ds);
    ctx.mna.stampAdmittance(d, s, Complex.real(gmin));
  }

  @override
  void reset() {
    _vgsPrev = 0.0;
    _started = false;
    _ds = const [];
  }
}
