class LivenessConfig {
  final double straightThreshold;
  final double turnThreshold;
  final int requiredFrames;
  final Duration phaseDuration;
  final Duration errorResetDuration;
  final int maxConsecutiveErrors;
  final double circleSize; // Added circleSize parameter

  const LivenessConfig({
    this.straightThreshold = 15.0,
    this.turnThreshold = 35.0, // Increased from 8.0 to 35.0
    this.requiredFrames = 10,
    this.phaseDuration = const Duration(milliseconds: 250),
    this.errorResetDuration = const Duration(seconds: 2),
    this.maxConsecutiveErrors = 5,
    this.circleSize = 250.0,
  });
}
