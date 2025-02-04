class LivenessConfig {
  final int requiredFrames;
  final int stateDuration;
  final double straightThreshold;
  final double turnThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;

  const LivenessConfig({
    this.requiredFrames = 5,
    this.stateDuration = 500,
    this.straightThreshold = 15.0,
    this.turnThreshold = 25.0,
    this.errorTimeout = const Duration(milliseconds: 1000),
    this.maxConsecutiveErrors = 3,
  });
}
