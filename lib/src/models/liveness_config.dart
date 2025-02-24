/*
class LivenessConfig {
  final int requiredFrames;
  final Duration phaseDuration;
  final double straightThreshold;
  final double turnThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;
  final double circleSize;

  const LivenessConfig({
    this.requiredFrames = 5,
    this.phaseDuration = const Duration(milliseconds: 250),
    this.straightThreshold = 10.0,
    this.turnThreshold = 8.0,
    this.errorTimeout = const Duration(milliseconds: 250),
    this.maxConsecutiveErrors = 3,
    this.circleSize = 0.8,
  });
}
*/

class LivenessConfig {
  final double straightThreshold;
  final double turnThreshold;
  final int requiredFrames;
  final Duration phaseDuration;
  final Duration errorResetDuration;
  final int maxConsecutiveErrors;

  const LivenessConfig({
    this.straightThreshold = 15.0,
    this.turnThreshold = 45.0,
    this.requiredFrames = 10,
    this.phaseDuration = const Duration(milliseconds: 500),
    this.errorResetDuration = const Duration(seconds: 2),
    this.maxConsecutiveErrors = 5,
  });
}
