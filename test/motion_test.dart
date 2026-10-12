// M3E motion token tests: m3e_core's motion system pins the
// M3 Expressive spring spec — spatial springs may overshoot,
// effect springs are critically damped. Token values are
// verified through the damping-coefficient identity
// damping = ratio * 2 * sqrt(mass * stiffness), because the
// package stores the ratio while the simulation needs the
// coefficient.

import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_core/m3e_core.dart';

void main() {
  group('expressive scheme springs', () {
    test('spatial tokens', () {
      _expectSpring(M3EMotion.expressiveSpatialFast,
          stiffness: 800, dampingRatio: 0.6);
      _expectSpring(M3EMotion.expressiveSpatialDefault,
          stiffness: 380, dampingRatio: 0.8);
      _expectSpring(M3EMotion.expressiveSpatialSlow,
          stiffness: 200, dampingRatio: 0.8);
    });

    test('effects tokens are critically damped', () {
      _expectSpring(M3EMotion.expressiveEffectsFast,
          stiffness: 3800, dampingRatio: 1.0);
      _expectSpring(M3EMotion.expressiveEffectsDefault,
          stiffness: 1600, dampingRatio: 1.0);
      _expectSpring(M3EMotion.expressiveEffectsSlow,
          stiffness: 800, dampingRatio: 1.0);
    });
  });

  group('standard scheme springs', () {
    test('spatial tokens', () {
      _expectSpring(M3EMotion.standardSpatialFast,
          stiffness: 1400, dampingRatio: 0.9);
      _expectSpring(M3EMotion.standardSpatialDefault,
          stiffness: 700, dampingRatio: 0.9);
      _expectSpring(M3EMotion.standardSpatialSlow,
          stiffness: 300, dampingRatio: 0.9);
    });

    test('effects tokens match the expressive stiffnesses', () {
      _expectSpring(M3EMotion.standardEffectsFast,
          stiffness: 3800, dampingRatio: 1.0);
      _expectSpring(M3EMotion.standardEffectsDefault,
          stiffness: 1600, dampingRatio: 1.0);
      _expectSpring(M3EMotion.standardEffectsSlow,
          stiffness: 800, dampingRatio: 1.0);
    });

    test('overflow and popup tokens', () {
      _expectSpring(M3EMotion.standardOverflow,
          stiffness: 1600, dampingRatio: 0.85);
      _expectSpring(M3EMotion.standardPopup,
          stiffness: 1000, dampingRatio: 0.6);
    });
  });

  group('toMotion', () {
    test('maps every token onto a unit-mass spring simulation', () {
      for (final m in const [
        M3EMotion.expressiveSpatialFast,
        M3EMotion.expressiveSpatialDefault,
        M3EMotion.expressiveSpatialSlow,
        M3EMotion.expressiveEffectsFast,
        M3EMotion.expressiveEffectsDefault,
        M3EMotion.expressiveEffectsSlow,
        M3EMotion.standardSpatialFast,
        M3EMotion.standardSpatialDefault,
        M3EMotion.standardSpatialSlow,
        M3EMotion.standardEffectsFast,
        M3EMotion.standardEffectsDefault,
        M3EMotion.standardEffectsSlow,
        M3EMotion.standardOverflow,
        M3EMotion.standardPopup,
      ]) {
        final description = m.toMotion().description;
        expect(description.mass, 1.0);
        expect(description.stiffness, m.stiffness);
        expect(
          description.damping,
          closeTo(m.damping * 2.0 * math.sqrt(m.stiffness), 1e-9),
        );
      }
    });
  });

  group('equality', () {
    test('tokens are value-equal', () {
      expect(
        M3EMotion.expressiveSpatialDefault,
        M3EMotion.expressiveSpatialDefault,
      );
      expect(
        M3EMotion.expressiveSpatialDefault ==
            M3EMotion.expressiveSpatialFast,
        isFalse,
      );
      expect(
        M3EMotion.custom(stiffness: 380, damping: 0.8),
        M3EMotion.expressiveSpatialDefault,
      );
    });
  });

  group('spring behavior', () {
    // Steps a 0 -> 1 simulation at 60fps for 5 fake seconds.
    List<double> trace(M3EMotion motion) {
      final sim = SpringSimulation(
        motion.toMotion().description,
        0.0,
        1.0,
        0.0,
      );
      final out = <double>[];
      for (var t = 0.0; t <= 5.0; t += 1 / 60) {
        out.add(sim.x(t));
      }
      return out;
    }

    test('spatial springs overshoot and settle at the target', () {
      final values = trace(M3EMotion.expressiveSpatialDefault);
      // Underdamped bounce past the target is intended.
      expect(values.reduce((a, b) => a > b ? a : b), greaterThan(1.0));
      expect(values.last, closeTo(1.0, 0.001));
    });

    test('effects springs never overshoot and settle at the target', () {
      final values = trace(M3EMotion.expressiveEffectsDefault);
      for (final v in values) {
        expect(v, lessThanOrEqualTo(1.0 + 1e-9));
      }
      expect(values.last, closeTo(1.0, 0.001));
    });
  });
}

void _expectSpring(
  M3EMotion motion, {
  required double stiffness,
  required double dampingRatio,
}) {
  expect(motion.stiffness, stiffness);
  expect(motion.damping, dampingRatio);
  expect(motion.snapToEnd, isFalse);
}
