class LivenessConfig {
  /// Number of steady frames required for state transitions
  final int requiredSteadyFrames;

  /// Threshold for considering face as centered (in degrees)
  final double centerThreshold;

  /// Threshold for head turn detection (in degrees)
  final double turnThreshold;

  /// Timeout duration for error tracking
  final Duration errorTimeout;

  /// Maximum number of consecutive errors before resetting
  final int maxConsecutiveErrors;

  /// Size of the face overlay circle (0.0 to 1.0)
  final double circleSize;

  const LivenessConfig({
    this.requiredSteadyFrames = 10,
    this.centerThreshold = 15.0,
    this.turnThreshold = 30.0,
    this.errorTimeout = const Duration(milliseconds: 500),
    this.maxConsecutiveErrors = 3,
    this.circleSize = 0.8,
  });
}
