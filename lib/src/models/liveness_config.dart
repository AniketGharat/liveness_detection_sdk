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
