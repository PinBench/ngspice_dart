import 'dart:typed_data';

import '../circuit/mna.dart';
import '../numeric/complex.dart';
import 'device.dart';

/// Linear capacitor between [n1] and [n2].
///
/// DC/OP: treated as an open circuit (no stamp).
/// Transient: replaced by its companion model (a conductance `g_eq` in parallel
/// with a current source `i_eq`). The first time step always uses Backward
/// Euler (no past current is required); subsequent steps use the configured
/// method (Trapezoidal by default).
/// AC: admittance `jωC`.
class Capacitor extends Device {
  final int n1;
  final int n2;

  /// Mutable so the interactive `alter` command can change it in place.
  double capacitance;

  /// Optional user-specified initial voltage (`ic=`).
  final double? initialVoltage;

  // History from the last accepted transient time point.
  double _vPrev = 0.0;
  double _iPrev = 0.0;
  bool _historyValid = false;

  // The conductance / Norton current actually stamped this step, so the true
  // branch current can be recovered exactly in [acceptTimestep].
  double _geq = 0.0;
  double _ieq = 0.0;

  Capacitor(super.name, this.n1, this.n2, this.capacitance,
      {this.initialVoltage});

  @override
  void stamp(StampContext ctx) {
    if (ctx.mode == AnalysisMode.operatingPoint ||
        ctx.mode == AnalysisMode.dc) {
      // Open circuit at DC.
      return;
    }

    final h = ctx.timeStep;
    if (h <= 0) return;

    if (ctx.integration == IntegrationMethod.trapezoidal && _historyValid) {
      _geq = 2.0 * capacitance / h;
      _ieq = _geq * _vPrev + _iPrev;
    } else {
      // Backward Euler (also the first step, where no past current exists).
      _geq = capacitance / h;
      _ieq = _geq * _vPrev;
    }

    ctx.mna.stampConductance(n1, n2, _geq);
    // Norton current source: pushes _ieq into n1 so that the recovered branch
    // current is i = _geq*v - _ieq.
    ctx.mna.stampCurrentSource(n2, n1, _ieq);
  }

  @override
  void stampAc(AcStampContext ctx) {
    ctx.mna.stampAdmittance(n1, n2, Complex(0, ctx.omega * capacitance));
  }

  @override
  void acceptTimestep(Float64List solution, double time, double timeStep) {
    final v1 = n1 < 0 ? 0.0 : solution[n1];
    final v2 = n2 < 0 ? 0.0 : solution[n2];
    final v = v1 - v2;
    if (timeStep > 0) {
      // Exact companion-model branch current for this step.
      _iPrev = _geq * v - _ieq;
    }
    _vPrev = v;
    _historyValid = true;
  }

  /// Primes the companion history with an initial voltage prior to t=0. Leaves
  /// history "invalid" so the first transient step uses Backward Euler.
  void setInitialState(double v) {
    _vPrev = v;
    _iPrev = 0.0;
    _historyValid = false;
  }

  @override
  void reset() {
    _vPrev = 0.0;
    _iPrev = 0.0;
    _historyValid = false;
    _geq = 0.0;
    _ieq = 0.0;
  }
}
