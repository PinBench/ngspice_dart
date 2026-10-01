import '../circuit/circuit.dart';
import '../devices/capacitor.dart';
import '../devices/controlled_sources.dart';
import '../devices/diode.dart';
import '../devices/inductor.dart';
import '../devices/resistor.dart';
import '../devices/sources.dart';
import '../devices/transistors.dart';
import '../devices/waveform.dart';
import 'value_parser.dart';

/// Raised when a netlist line cannot be understood.
class NetlistParseException implements Exception {
  final String message;
  final String line;
  NetlistParseException(this.message, this.line);
  @override
  String toString() => 'NetlistParseException: $message\n  in: "$line"';
}

/// Parses a SPICE netlist (a list of source lines) into a [Circuit].
class NetlistParser {
  /// Named `.model` definitions, keyed by lower-case model name.
  final Map<String, DiodeModel> _diodeModels = {};
  final Map<String, BjtModel> _bjtModels = {};
  final Map<String, MosfetModel> _mosfetModels = {};

  Circuit parse(List<String> rawLines) {
    final circuit = Circuit();
    final lines = _preprocess(rawLines);

    // Models first: SPICE lets a `.model` card follow the elements that use
    // it, and a transistor cannot be built without its model.
    for (final line in lines) {
      if (line.toLowerCase().startsWith('.model')) {
        _parseModel(_tokenize(line), line);
      }
    }

    var first = true;
    for (final line in lines) {
      if (line.isEmpty) continue;

      // The very first non-empty line of a deck is the title, unless it is a
      // control/element line. SPICE always treats line 1 as the title.
      if (first) {
        first = false;
        if (line.startsWith('.')) {
          // No title; fall through to handle the directive.
        } else {
          circuit.title =
              line.startsWith('*') ? line.substring(1).trim() : line.trim();
          continue;
        }
      }

      if (line.startsWith('*')) continue; // comment

      if (line.startsWith('.')) {
        _parseDirective(line, circuit);
      } else {
        _parseElement(line, circuit);
      }
    }

    circuit.build();
    return circuit;
  }

  // --- Preprocessing -------------------------------------------------------

  /// Joins `+` continuation lines, strips inline comments, trims whitespace.
  List<String> _preprocess(List<String> raw) {
    final out = <String>[];
    for (var line in raw) {
      line = _stripInlineComment(line);
      final trimmed = line.trimRight();
      if (trimmed.trimLeft().startsWith('+')) {
        // Continuation: append to the previous logical line.
        final cont = trimmed.trimLeft().substring(1).trim();
        if (out.isNotEmpty) {
          out[out.length - 1] = '${out.last} $cont';
        } else {
          out.add(cont);
        }
      } else {
        out.add(trimmed.trim());
      }
    }
    return out;
  }

  String _stripInlineComment(String line) {
    // `$` and `;` begin trailing comments in ngspice. A leading `*` is a full
    // comment line and is handled by the caller.
    var inParen = 0;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '(') inParen++;
      if (ch == ')') inParen > 0 ? inParen-- : 0;
      if ((ch == ';' || ch == '\$') && inParen == 0) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  List<String> _tokenize(String line) =>
      line.split(RegExp(r'[\s,]+')).where((t) => t.isNotEmpty).toList();

  /// Tokenizes treating parentheses as whitespace (for source value lists).
  List<String> _tokenizeFlat(String s) => s
      .replaceAll('(', ' ')
      .replaceAll(')', ' ')
      .split(RegExp(r'[\s,]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  // --- Elements ------------------------------------------------------------

  void _parseElement(String line, Circuit circuit) {
    final tokens = _tokenize(line);
    if (tokens.isEmpty) return;
    final name = tokens[0];
    final type = name[0].toUpperCase();

    switch (type) {
      case 'R':
        _parseResistor(tokens, line, circuit);
        break;
      case 'C':
        _parseCapacitor(tokens, line, circuit);
        break;
      case 'L':
        _parseInductor(tokens, line, circuit);
        break;
      case 'V':
        _parseSource(tokens, line, circuit, isVoltage: true);
        break;
      case 'I':
        _parseSource(tokens, line, circuit, isVoltage: false);
        break;
      case 'D':
        _parseDiode(tokens, line, circuit);
        break;
      case 'E':
        _parseControlled(tokens, line, circuit, voltageOutput: true);
        break;
      case 'G':
        _parseControlled(tokens, line, circuit, voltageOutput: false);
        break;
      case 'Q':
        _parseBjt(tokens, line, circuit);
        break;
      case 'M':
        _parseMosfet(tokens, line, circuit);
        break;
      default:
        throw NetlistParseException('Unsupported element type "$type"', line);
    }
  }

  void _parseResistor(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 4) {
      throw NetlistParseException('Expected: Rxxx n1 n2 value', line);
    }
    final a = circuit.node(tokens[1]);
    final b = circuit.node(tokens[2]);
    final value = SpiceValue.tryParse(tokens[3]);
    if (value == null || value == 0) {
      throw NetlistParseException('Invalid resistance "${tokens[3]}"', line);
    }
    circuit.add(Resistor(tokens[0], a, b, value));
  }

  void _parseCapacitor(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 4) {
      throw NetlistParseException('Expected: Cxxx n1 n2 value', line);
    }
    final a = circuit.node(tokens[1]);
    final b = circuit.node(tokens[2]);
    final value = SpiceValue.tryParse(tokens[3]);
    if (value == null) {
      throw NetlistParseException('Invalid capacitance "${tokens[3]}"', line);
    }
    final ic = _findIc(tokens);
    circuit.add(Capacitor(tokens[0], a, b, value, initialVoltage: ic));
  }

  void _parseInductor(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 4) {
      throw NetlistParseException('Expected: Lxxx n1 n2 value', line);
    }
    final a = circuit.node(tokens[1]);
    final b = circuit.node(tokens[2]);
    final value = SpiceValue.tryParse(tokens[3]);
    if (value == null) {
      throw NetlistParseException('Invalid inductance "${tokens[3]}"', line);
    }
    final ic = _findIc(tokens);
    circuit.add(Inductor(tokens[0], a, b, value, initialCurrent: ic));
  }

  double? _findIc(List<String> tokens) {
    for (final t in tokens) {
      final lower = t.toLowerCase();
      if (lower.startsWith('ic=')) {
        return SpiceValue.tryParse(t.substring(3));
      }
    }
    return null;
  }

  void _parseDiode(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 3) {
      throw NetlistParseException('Expected: Dxxx anode cathode [model]', line);
    }
    final a = circuit.node(tokens[1]);
    final c = circuit.node(tokens[2]);
    DiodeModel model = const DiodeModel();
    if (tokens.length >= 4) {
      model = _diodeModels[tokens[3].toLowerCase()] ?? const DiodeModel();
    }
    circuit.add(Diode(tokens[0], a, c, model));
  }

  /// `Qxxx nc nb ne [ns] model [area]` — the model is the first token after
  /// the three terminals that names a BJT model; a substrate node is ignored.
  void _parseBjt(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 5) {
      throw NetlistParseException('Expected: Qxxx nc nb ne model', line);
    }
    final model = tokens
        .skip(4)
        .map((t) => _bjtModels[t.toLowerCase()])
        .firstWhere((m) => m != null, orElse: () => null);
    if (model == null) {
      throw NetlistParseException('No NPN/PNP .model for ${tokens[0]}', line);
    }
    circuit.add(Bjt(tokens[0], circuit.node(tokens[1]), circuit.node(tokens[2]),
        circuit.node(tokens[3]), model));
  }

  /// `Mxxx nd ng ns nb model [L=..] [W=..]` — the body node is accepted and
  /// assumed tied to the source.
  void _parseMosfet(List<String> tokens, String line, Circuit circuit) {
    if (tokens.length < 6) {
      throw NetlistParseException('Expected: Mxxx nd ng ns nb model', line);
    }
    final model = _mosfetModels[tokens[5].toLowerCase()];
    if (model == null) {
      throw NetlistParseException('No NMOS/PMOS .model for ${tokens[0]}', line);
    }
    double dimension(String key) {
      for (final t in tokens.skip(6)) {
        final eq = t.indexOf('=');
        if (eq > 0 && t.substring(0, eq).toLowerCase() == key) {
          return SpiceValue.tryParse(t.substring(eq + 1)) ?? 1.0;
        }
      }
      return 1.0;
    }

    circuit.add(Mosfet(tokens[0], circuit.node(tokens[1]),
        circuit.node(tokens[2]), circuit.node(tokens[3]), model,
        aspect: dimension('w') / dimension('l')));
  }

  void _parseControlled(List<String> tokens, String line, Circuit circuit,
      {required bool voltageOutput}) {
    // Exxx/Gxxx n+ n- nc+ nc- gain
    if (tokens.length < 6) {
      throw NetlistParseException(
          'Expected: ${tokens[0]} n+ n- nc+ nc- gain', line);
    }
    final nPlus = circuit.node(tokens[1]);
    final nMinus = circuit.node(tokens[2]);
    final ncPlus = circuit.node(tokens[3]);
    final ncMinus = circuit.node(tokens[4]);
    final gain = SpiceValue.tryParse(tokens[5]);
    if (gain == null) {
      throw NetlistParseException('Invalid gain "${tokens[5]}"', line);
    }
    if (voltageOutput) {
      circuit.add(Vcvs(tokens[0], nPlus, nMinus, ncPlus, ncMinus, gain));
    } else {
      circuit.add(Vccs(tokens[0], nPlus, nMinus, ncPlus, ncMinus, gain));
    }
  }

  void _parseSource(List<String> tokens, String line, Circuit circuit,
      {required bool isVoltage}) {
    if (tokens.length < 3) {
      throw NetlistParseException('Expected: name n+ n- ...', line);
    }
    final nPlus = circuit.node(tokens[1]);
    final nMinus = circuit.node(tokens[2]);
    final waveform = _parseWaveform(tokens.sublist(3), line);
    if (isVoltage) {
      circuit.add(VoltageSource(tokens[0], nPlus, nMinus, waveform));
    } else {
      circuit.add(CurrentSource(tokens[0], nPlus, nMinus, waveform));
    }
  }

  SourceWaveform _parseWaveform(List<String> valueTokens, String line) {
    final flat = _tokenizeFlat(valueTokens.join(' '));
    double dc = 0;
    double acMag = 0;
    double acPhase = 0;
    TransientFunction? transient;
    var sawDc = false;

    var i = 0;
    while (i < flat.length) {
      final tok = flat[i];
      final lower = tok.toLowerCase();
      if (lower == 'dc') {
        i++;
        if (i < flat.length) {
          dc = SpiceValue.tryParse(flat[i]) ?? 0;
          sawDc = true;
        }
        i++;
      } else if (lower == 'ac') {
        i++;
        if (i < flat.length && SpiceValue.tryParse(flat[i]) != null) {
          acMag = SpiceValue.tryParse(flat[i])!;
          i++;
          if (i < flat.length && SpiceValue.tryParse(flat[i]) != null) {
            acPhase = SpiceValue.tryParse(flat[i])!;
            i++;
          }
        }
      } else if (lower == 'sin' || lower == 'sine') {
        final args = _consumeNumbers(flat, i + 1);
        transient = _buildSin(args.values);
        i = args.next;
      } else if (lower == 'pulse') {
        final args = _consumeNumbers(flat, i + 1);
        transient = _buildPulse(args.values);
        i = args.next;
      } else if (lower == 'pwl') {
        final args = _consumeNumbers(flat, i + 1);
        transient = _buildPwl(args.values);
        i = args.next;
      } else {
        // A bare number: the first one is the DC value.
        final v = SpiceValue.tryParse(tok);
        if (v != null && !sawDc) {
          dc = v;
          sawDc = true;
        }
        i++;
      }
    }

    return SourceWaveform(
        dc: dc, acMag: acMag, acPhase: acPhase, transient: transient);
  }

  ({List<double> values, int next}) _consumeNumbers(
      List<String> flat, int start) {
    final values = <double>[];
    var i = start;
    while (i < flat.length) {
      final v = SpiceValue.tryParse(flat[i]);
      if (v == null) break;
      values.add(v);
      i++;
    }
    return (values: values, next: i);
  }

  TransientFunction _buildSin(List<double> a) {
    double at(int i) => i < a.length ? a[i] : 0.0;
    return SinFunction(at(0), at(1), at(2),
        td: at(3), theta: at(4), phaseDeg: at(5));
  }

  TransientFunction _buildPulse(List<double> a) {
    double at(int i) => i < a.length ? a[i] : 0.0;
    return PulseFunction(at(0), at(1),
        td: at(2), tr: at(3), tf: at(4), pw: at(5), per: at(6));
  }

  TransientFunction _buildPwl(List<double> a) {
    final times = <double>[];
    final values = <double>[];
    for (var i = 0; i + 1 < a.length; i += 2) {
      times.add(a[i]);
      values.add(a[i + 1]);
    }
    return PwlFunction(times, values);
  }

  // --- Directives ----------------------------------------------------------

  void _parseDirective(String line, Circuit circuit) {
    final tokens = _tokenize(line);
    final dir = tokens[0].toLowerCase();
    switch (dir) {
      case '.end':
      case '.ends':
        break;
      case '.op':
        circuit.analyses.add(OpDirective());
        break;
      case '.tran':
        circuit.analyses.add(_parseTran(tokens, line));
        break;
      case '.dc':
        circuit.analyses.add(_parseDc(tokens, line));
        break;
      case '.ac':
        circuit.analyses.add(_parseAc(tokens, line));
        break;
      case '.model':
        _parseModel(tokens, line);
        break;
      case '.option':
      case '.options':
        _parseOptions(tokens, circuit);
        break;
      case '.ic':
        // Handled by the transient driver via parsed values; store as options
        // would lose node mapping, so we attach to circuit lazily later.
        _parseIc(tokens, circuit);
        break;
      case '.print':
      case '.plot':
      case '.save':
      case '.width':
      case '.temp':
        // Recognised but not acted upon yet.
        break;
      default:
        // Unknown directive: ignore rather than fail the whole deck.
        break;
    }
  }

  TranDirective _parseTran(List<String> tokens, String line) {
    if (tokens.length < 3) {
      throw NetlistParseException('Expected: .tran tstep tstop', line);
    }
    final tstep = SpiceValue.tryParse(tokens[1]);
    final tstop = SpiceValue.tryParse(tokens[2]);
    if (tstep == null || tstop == null) {
      throw NetlistParseException('Invalid .tran timing', line);
    }
    double tstart = 0;
    double tmax = 0;
    if (tokens.length >= 4) tstart = SpiceValue.tryParse(tokens[3]) ?? 0;
    if (tokens.length >= 5) tmax = SpiceValue.tryParse(tokens[4]) ?? 0;
    final uic = tokens.any((t) => t.toLowerCase() == 'uic');
    return TranDirective(tstep, tstop,
        tstart: tstart, tmax: tmax, useInitialConditions: uic);
  }

  DcDirective _parseDc(List<String> tokens, String line) {
    if (tokens.length < 5) {
      throw NetlistParseException('Expected: .dc source start stop step', line);
    }
    final start = SpiceValue.tryParse(tokens[2]);
    final stop = SpiceValue.tryParse(tokens[3]);
    final step = SpiceValue.tryParse(tokens[4]);
    if (start == null || stop == null || step == null) {
      throw NetlistParseException('Invalid .dc sweep values', line);
    }
    return DcDirective(tokens[1], start, stop, step);
  }

  AcDirective _parseAc(List<String> tokens, String line) {
    if (tokens.length < 5) {
      throw NetlistParseException(
          'Expected: .ac dec|oct|lin n fstart fstop', line);
    }
    final type = switch (tokens[1].toLowerCase()) {
      'dec' => AcSweepType.dec,
      'oct' => AcSweepType.oct,
      'lin' => AcSweepType.lin,
      _ => throw NetlistParseException('Unknown AC sweep "${tokens[1]}"', line),
    };
    final n = int.tryParse(tokens[2]);
    final fStart = SpiceValue.tryParse(tokens[3]);
    final fStop = SpiceValue.tryParse(tokens[4]);
    if (n == null || fStart == null || fStop == null) {
      throw NetlistParseException('Invalid .ac parameters', line);
    }
    return AcDirective(type, n, fStart, fStop);
  }

  void _parseModel(List<String> tokens, String line) {
    if (tokens.length < 3) return;
    final name = tokens[1].toLowerCase();
    final typePart = tokens[2];
    // Model type may be `D` or `D(...)`; parameters follow as key=value.
    final type = RegExp(r'^[a-z]+').stringMatch(typePart.toLowerCase()) ?? '';

    final params = <String, double>{};
    final joined = tokens.sublist(2).join(' ');
    final flat = joined.replaceAll('(', ' ').replaceAll(')', ' ');
    for (final match in RegExp(r'(\w+)\s*=\s*([^\s]+)').allMatches(flat)) {
      final key = match.group(1)!.toLowerCase();
      final v = SpiceValue.tryParse(match.group(2)!);
      if (v != null) params[key] = v;
    }
    final temp = (params['tnom'] ?? 26.85) + 273.15;

    switch (type) {
      case 'npn' || 'pnp':
        _bjtModels[name] = BjtModel(
          pnp: type == 'pnp',
          isat: params['is'] ?? 1e-16,
          bf: params['bf'] ?? 100,
          br: params['br'] ?? 1,
          nf: params['nf'] ?? 1,
          nr: params['nr'] ?? 1,
          temp: temp,
        );
        return;
      case 'nmos' || 'pmos':
        _mosfetModels[name] = MosfetModel(
          pmos: type == 'pmos',
          vto: params['vto'] ?? 0,
          kp: params['kp'] ?? 2e-5,
          lambda: params['lambda'] ?? 0,
        );
        return;
      case 'd':
        break;
      default:
        return;
    }
    _diodeModels[name] = DiodeModel(
      isat: params['is'] ?? 1e-14,
      n: params['n'] ?? 1.0,
      rs: params['rs'] ?? 0.0,
      temp: temp,
    );
  }

  void _parseOptions(List<String> tokens, Circuit circuit) {
    for (final t in tokens.skip(1)) {
      final eq = t.indexOf('=');
      if (eq > 0) {
        final key = t.substring(0, eq).toLowerCase();
        final v = SpiceValue.tryParse(t.substring(eq + 1));
        if (v != null) circuit.options[key] = v;
      }
    }
  }

  void _parseIc(List<String> tokens, Circuit circuit) {
    for (final t in tokens.skip(1)) {
      // Form: v(node)=value
      final m = RegExp(r'v\(([^)]+)\)\s*=\s*(.+)', caseSensitive: false)
          .firstMatch(t);
      if (m != null) {
        final v = SpiceValue.tryParse(m.group(2)!);
        if (v != null) {
          circuit.options['ic.${m.group(1)!.toLowerCase()}'] = v;
        }
      }
    }
  }
}
