import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter_compass/flutter_compass.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

/// Tracks live position via pedestrian dead reckoning (PDR): each detected
/// step (from the OS's native step counter) advances a position estimate
/// by one step-length in the current compass heading direction.
///
/// PDR alone drifts over time — [NavigationController] periodically resets
/// the accumulated position back to a known beacon location whenever BLE
/// zone-snap fires a new fix, which is the "fusion" between the two.
class MotionService {
  MotionService({
    required this.metersPerUnit,
    required this.mapNorthOffsetDegrees,
    this.stepLengthMeters = 0.75,
  });

  /// Real-world meters per one map/SVG coordinate unit (see [StoreMap]).
  final double metersPerUnit;

  /// Compass bearing (degrees, 0 = North) that corresponds to the map's
  /// "up" (-y) direction — used to rotate compass headings into map space.
  final double mapNorthOffsetDegrees;

  /// Assumed distance covered per step. A rough average adult stride;
  /// personalize/calibrate later if needed.
  final double stepLengthMeters;

  final _deltaController = StreamController<Offset>.broadcast();
  final _headingController = StreamController<double>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  StreamSubscription<StepCount>? _stepSub;
  StreamSubscription<CompassEvent>? _compassSub;

  int? _lastStepCount;
  double? _latestHeadingDegrees;

  /// Map-space position deltas (map units), one per detected step.
  Stream<Offset> get positionDeltas => _deltaController.stream;

  /// Live compass heading in degrees (0 = North), updated independently of
  /// steps so the arrow can rotate even while standing still.
  Stream<double> get headingStream => _headingController.stream;

  /// Human-readable reasons motion tracking couldn't start — e.g. a denied
  /// permission or a missing sensor. Surfaced instead of failing silently,
  /// same reasoning as [BleScannerService.errors].
  Stream<String> get errors => _errorController.stream;

  Future<void> start() async {
    final status = await Permission.activityRecognition.request();
    if (!status.isGranted) {
      _errorController.add('Motion permission denied — step tracking disabled. Grant it in system settings.');
      return;
    }

    final compassEvents = FlutterCompass.events;
    if (compassEvents == null) {
      _errorController.add('Compass not available on this device.');
    } else {
      _compassSub = compassEvents.listen((event) {
        final heading = event.heading;
        if (heading == null) return;
        final smoothed = _smoothHeading(_latestHeadingDegrees, heading);
        _latestHeadingDegrees = smoothed;
        _headingController.add(smoothed);
      });
    }

    _stepSub = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: (Object e) => _errorController.add('Step counter error: $e'),
    );
  }

  void _onStepCount(StepCount event) {
    final last = _lastStepCount;
    _lastStepCount = event.steps;
    if (last == null) return; // First reading is just a baseline.

    final newSteps = event.steps - last;
    if (newSteps <= 0) return;

    final heading = _latestHeadingDegrees;
    if (heading == null) return; // No heading yet — can't determine direction.

    final distanceMeters = newSteps * stepLengthMeters;
    final distanceUnits = distanceMeters / metersPerUnit;
    final theta = (heading - mapNorthOffsetDegrees) * math.pi / 180;
    final delta = Offset(distanceUnits * math.sin(theta), -distanceUnits * math.cos(theta));
    _deltaController.add(delta);
  }

  /// Exponential moving average that handles the 0°/360° wraparound
  /// correctly by averaging in Cartesian (unit-vector) space rather than
  /// raw degrees — naively averaging e.g. 350° and 10° would otherwise give
  /// 180° instead of ~0°. Smooths out magnetometer noise (common indoors,
  /// near structural metal/electronics) that otherwise sends a whole batch
  /// of steps off in a wildly wrong direction on a single bad reading —
  /// the main cause of the live position "jumping" instead of moving
  /// smoothly. [alpha] close to 0 = heavier smoothing (more lag on real
  /// turns); close to 1 = lighter smoothing (more noise gets through).
  double _smoothHeading(double? previous, double next, {double alpha = 0.15}) {
    if (previous == null) return next;
    final prevRad = previous * math.pi / 180;
    final nextRad = next * math.pi / 180;
    final x = (1 - alpha) * math.cos(prevRad) + alpha * math.cos(nextRad);
    final y = (1 - alpha) * math.sin(prevRad) + alpha * math.sin(nextRad);
    var result = math.atan2(y, x) * 180 / math.pi;
    if (result < 0) result += 360;
    return result;
  }

  void stop() {
    _stepSub?.cancel();
    _stepSub = null;
    _compassSub?.cancel();
    _compassSub = null;
  }

  void dispose() {
    stop();
    _deltaController.close();
    _headingController.close();
    _errorController.close();
  }
}
