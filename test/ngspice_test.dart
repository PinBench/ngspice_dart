import 'package:test/test.dart';
import 'package:ngspice_dart/ngspice_dart.dart';

void main() {
  group('Ngspice Initialization and Execution', () {
    late Ngspice ngspice;

    setUpAll(() {
      ngspice = Ngspice();
    });

    test('should initialize successfully', () {
      final initResult = ngspice.init();
      expect(initResult, equals(0),
          reason: 'Initialization should return 0 (success)');
    });

    test('should execute a simple command', () {
      final cmdResult = ngspice.command('print all');
      expect(cmdResult, equals(0),
          reason: 'Command execution should return 0 (success)');
    });

    test('should load a simple RC circuit', () {
      final circResult = ngspice.circuit([
        '* A simple RC circuit',
        'v1 1 0 dc 5',
        'r1 1 2 1k',
        'c1 2 0 1u',
        '.tran 0.1m 10m',
        '.end'
      ]);
      expect(circResult, equals(0),
          reason: 'Circuit loading should return 0 (success)');
    });

    test('should run the simulation', () {
      final runResult = ngspice.command('run');
      expect(runResult, equals(0),
          reason: 'Simulation run should return 0 (success)');
    });

    test('should get vector data', () {
      final vec = ngspice.getVector('v(1)');
      expect(vec, isNotNull);
      expect(vec!.isNotEmpty, isTrue);
      // Since it's a step simulation or tran, we should have values.
      expect(vec.first, closeTo(5.0, 1e-4));
    });
  });

  group('alter command', () {
    // A driven node through a series resistor to ground: the branch current of
    // the source is V/R, so altering V must change the operating point on the
    // next `op` without reloading the netlist.
    Ngspice loadDivider() {
      final ng = Ngspice()..init();
      ng.circuit([
        '* alter regression: source -> 1k -> ground',
        'V1 1 0 dc 0',
        'R1 1 0 1k',
        '.op',
        '.end',
      ]);
      return ng;
    }

    test('alter <name> = <value> updates the source on the next op', () {
      final ng = loadDivider();

      expect(ng.command('alter V1 = 5'), equals(0));
      ng.command('op');
      // i(V1) is the branch current flowing +->- through the source: -V/R.
      expect(ng.getVector('i(V1)')!.first, closeTo(-5.0 / 1000.0, 1e-9));

      // Re-altering the same source must take effect again.
      expect(ng.command('alter V1 = 2'), equals(0));
      ng.command('op');
      expect(ng.getVector('i(V1)')!.first, closeTo(-2.0 / 1000.0, 1e-9));
    });

    test('alter accepts the space-separated form', () {
      final ng = loadDivider();
      ng.command('alter V1 3');
      ng.command('op');
      expect(ng.getVector('v(1)')!.first, closeTo(3.0, 1e-9));
    });

    test('alter changes a resistor in place, as a switch or sensor needs', () {
      final ng = Ngspice()..init();
      ng.circuit([
        '* divider whose lower leg is altered',
        'V1 1 0 dc 10',
        'R1 1 2 1k',
        'R2 2 0 1k',
        '.op',
        '.end',
      ]);
      ng.command('op');
      expect(ng.getVector('v(2)')!.first, closeTo(5.0, 1e-9));

      expect(ng.command('alter R2 = 3000'), equals(0));
      ng.command('op');
      expect(ng.getVector('v(2)')!.first, closeTo(7.5, 1e-9));
    });

    test('a zero or negative resistance is refused, not divided by', () {
      final ng = loadDivider();
      expect(ng.command('alter R1 = 0'), equals(1));
    });

    test('altering an unknown source reports failure', () {
      final ng = loadDivider();
      expect(ng.command('alter V_missing = 5'), equals(1));
    });
  });
}
