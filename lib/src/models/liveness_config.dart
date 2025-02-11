class LivenessConfig {
  final int requiredFrames;
  final Duration phaseDuration;
  final double straightThreshold;
  final double turnThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;
  final double circleSize;

  const LivenessConfig({
    this.requiredFrames = 10, // Increased from 5
    this.phaseDuration =
        const Duration(milliseconds: 1500), // Increased from 500
    this.straightThreshold = 10.0,
    this.turnThreshold = 15.0,
    this.errorTimeout = const Duration(milliseconds: 500),
    this.maxConsecutiveErrors = 2,
    this.circleSize = 0.8,
  });
}
