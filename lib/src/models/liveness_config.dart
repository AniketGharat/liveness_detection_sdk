class LivenessConfig {
  final int requiredFrames;
  final Duration phaseDuration;
  final double straightThreshold;
  final double turnThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;
  final double circleSize;
  final Function(bool)? onFaceDetected;
  final Function(bool)? onMultipleFaces;

  const LivenessConfig({
    this.requiredFrames = 20,
    this.phaseDuration = const Duration(seconds: 2),
    this.straightThreshold = 10.0,
    this.turnThreshold = 20.0,
    this.errorTimeout = const Duration(seconds: 1),
    this.maxConsecutiveErrors = 3,
    this.circleSize = 0.65,
    this.onFaceDetected,
    this.onMultipleFaces,
  });
}
