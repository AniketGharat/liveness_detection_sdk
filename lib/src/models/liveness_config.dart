class LivenessConfig {
  final int requiredFrames;
  final Duration phaseDuration;
  final double straightThreshold;
  final double turnThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;
  final double circleSize;

  const LivenessConfig({
    this.requiredFrames = 2,
    this.phaseDuration = const Duration(milliseconds: 1000),
    this.straightThreshold = 12.0,
    this.turnThreshold = 12.0,
    this.errorTimeout = const Duration(milliseconds: 300),
    this.maxConsecutiveErrors = 3,
    this.circleSize = 0.8,
  });
}
