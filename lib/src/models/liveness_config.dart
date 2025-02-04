import 'package:camera/camera.dart';

class LivenessConfig {
  final int requiredFrames;
  final int stateDuration;
  final double minFaceSize;
  final double straightThreshold;
  final double turnThreshold;
  final double blinkThreshold;
  final Duration errorTimeout;
  final int maxConsecutiveErrors;
  final bool requireBlink;
  final ResolutionPreset cameraResolution;

  const LivenessConfig({
    this.requiredFrames = 5,
    this.stateDuration = 500,
    this.minFaceSize = 0.25,
    this.straightThreshold = 15.0,
    this.turnThreshold = 25.0,
    this.blinkThreshold = 0.2,
    this.errorTimeout = const Duration(milliseconds: 1000),
    this.maxConsecutiveErrors = 3,
    this.requireBlink = true,
    this.cameraResolution = ResolutionPreset.medium,
  });
}
