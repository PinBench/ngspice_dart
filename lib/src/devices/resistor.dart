import '../numeric/complex.dart';
import 'device.dart';

/// Linear resistor between nodes [n1] and [n2] with resistance [resistance].
///
/// [resistance] is mutable so the interactive `alter` command can change it
/// in place, as it does a source's value: a part whose resistance follows
/// the simulation — a light-dependent resistor, a switch — must not need the
/// circuit rebuilt.
class Resistor extends Device {
  final int n1;
  final int n2;
  double resistance;

  Resistor(super.name, this.n1, this.n2, this.resistance);

  double get conductance => 1.0 / resistance;

  @override
  void stamp(StampContext ctx) {
    ctx.mna.stampConductance(n1, n2, conductance);
  }

  @override
  void stampAc(AcStampContext ctx) {
    ctx.mna.stampAdmittance(n1, n2, Complex.real(conductance));
  }
}
