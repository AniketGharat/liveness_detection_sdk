import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;
  final bool isFrontCamera;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  bool _isWaitingForNextState = false;
  int _steadyFrameCount = 0;
  static const int requiredSteadyFrames = 10;

  LivenessDetector({
    required this.config,
    required this.onStateChanged,
    required this.isFrontCamera,
  }) {
    _initializeFaceDetector();
    _updateState(LivenessState.initial);
  }

  void _initializeFaceDetector() {
    final options = FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.accurate,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing || _currentState == LivenessState.complete) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _handleNoFace();
      } else if (faces.length > 1) {
        _handleMultipleFaces();
      } else {
        await _processDetectedFace(faces.first);
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
      _handleError();
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _processDetectedFace(Face face) async {
    // Adjust headEulerY based on camera type
    var headEulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      // Invert the angle for back camera
      headEulerY = -headEulerY;
    }

    final now = DateTime.now();
    _stateStartTime ??= now;

    if (_lastStateChange != null &&
        now.difference(_lastStateChange!) < config.phaseDuration) {
      return;
    }

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _steadyFrameCount++;
          if (_steadyFrameCount >= requiredSteadyFrames) {
            _updateState(LivenessState.lookingLeft);
            _steadyFrameCount = 0;
          }
        } else {
          _steadyFrameCount = 0;
        }
        break;

      case LivenessState.lookingLeft:
        final threshold =
            isFrontCamera ? -config.turnThreshold : config.turnThreshold;
        if ((isFrontCamera ? headEulerY > threshold : headEulerY < threshold) &&
            !_hasCompletedLeft) {
          _steadyFrameCount++;
          if (_steadyFrameCount >= requiredSteadyFrames) {
            _hasCompletedLeft = true;
            _updateState(LivenessState.lookingRight);
            _steadyFrameCount = 0;
          }
        } else {
          _steadyFrameCount = 0;
        }
        break;

      case LivenessState.lookingRight:
        final threshold =
            isFrontCamera ? config.turnThreshold : -config.turnThreshold;
        if ((isFrontCamera ? headEulerY < threshold : headEulerY > threshold) &&
            !_hasCompletedRight) {
          _steadyFrameCount++;
          if (_steadyFrameCount >= requiredSteadyFrames) {
            _hasCompletedRight = true;
            _updateState(LivenessState.lookingStraight);
            _steadyFrameCount = 0;
          }
        } else {
          _steadyFrameCount = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (_isFaceCentered(face)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _updateState(LivenessState.complete);
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      default:
        break;
    }
  }

  bool _isFaceCentered(Face face) {
    var eulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      eulerY = -eulerY;
    }
    final eulerZ = face.headEulerAngleZ ?? 0.0;
    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  void _handleNoFace() {
    _updateState(LivenessState.initial);
    _incrementErrorCount();
  }

  void _handleMultipleFaces() {
    _updateState(LivenessState.multipleFaces);
    _incrementErrorCount();
  }

  void _handleError() {
    _incrementErrorCount();
  }

  void _incrementErrorCount() {
    final now = DateTime.now();
    if (_lastErrorTime != null &&
        now.difference(_lastErrorTime!) > config.errorTimeout) {
      _consecutiveErrors = 0;
    }
    _lastErrorTime = now;
    _consecutiveErrors++;

    if (_consecutiveErrors >= config.maxConsecutiveErrors) {
      _resetProgress();
    }
  }

  void _resetProgress() {
    _stableFrameCount = 0;
    _hasCompletedLeft = false;
    _hasCompletedRight = false;
    _consecutiveErrors = 0;
    _lastErrorTime = null;
    _updateState(LivenessState.initial);
  }

  double _calculateProgress(LivenessState state) {
    return switch (state) {
      LivenessState.initial => 0.0,
      LivenessState.lookingLeft => 0.25,
      LivenessState.lookingRight => 0.50,
      LivenessState.lookingStraight => 0.75,
      LivenessState.complete => 1.0,
      LivenessState.multipleFaces => 0.0,
    };
  }

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    _lastStateChange = DateTime.now();
    _isWaitingForNextState = false;

    final progress = _calculateProgress(newState);
    final message = _getMessageForState(newState);
    final animation = _getAnimationForState(newState);

    onStateChanged(newState, progress, message, animation);
  }

  String _getMessageForState(LivenessState state) {
    final leftRight = isFrontCamera ? ["left", "right"] : ["right", "left"];
    return switch (state) {
      LivenessState.initial => "Position your face in the circle",
      LivenessState.lookingLeft => "Turn your head ${leftRight[0]} slowly",
      LivenessState.lookingRight => "Turn your head ${leftRight[1]} slowly",
      LivenessState.lookingStraight => "Look straight ahead",
      LivenessState.complete => "Perfect! Processing...",
      LivenessState.multipleFaces => "Only one face should be visible",
    };
  }

  String _getAnimationForState(LivenessState state) {
    // Use same animation files for both cameras
    return switch (state) {
      LivenessState.initial => 'assets/animations/face_scan_init.json',
      LivenessState.lookingLeft => 'assets/animations/look_left.json',
      LivenessState.lookingRight => 'assets/animations/look_right.json',
      LivenessState.lookingStraight => 'assets/animations/look_straight.json',
      LivenessState.complete => 'assets/animations/face_success.json',
      LivenessState.multipleFaces => 'assets/animations/multiple_faces.json',
    };
  }

  void dispose() {
    _faceDetector.close();
  }
}
