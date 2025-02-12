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

  // New variables for improved state management
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  int _steadyFrameCount = 0;
  double _lastEulerY = 0.0;

  // Constants for validation
  static const int requiredSteadyFrames = 15; // Increased from 10
  static const Duration minStateTime = Duration(milliseconds: 1000);
  static const Duration angleStabilityTime = Duration(milliseconds: 500);
  static const double angleChangeTolerance = 5.0;

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

    final InputImageRotation rotation = isFrontCamera
        ? InputImageRotation.rotation270deg
        : InputImageRotation.rotation90deg;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
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
    var headEulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      headEulerY = -headEulerY;
    }

    final now = DateTime.now();
    _stateStartTime ??= now;

    // Check if angle has changed significantly
    if ((_lastEulerY - headEulerY).abs() > angleChangeTolerance) {
      _lastValidAngle = now;
      _steadyFrameCount = 0;
    }
    _lastEulerY = headEulerY;

    // Ensure minimum time in state before transitions
    if (_lastStateChange != null &&
        now.difference(_lastStateChange!) < minStateTime) {
      return;
    }

    switch (_currentState) {
      case LivenessState.initial:
        await _handleInitialState(face, headEulerY);
        break;
      case LivenessState.lookingLeft:
        await _handleLookingLeftState(face, headEulerY);
        break;
      case LivenessState.lookingRight:
        await _handleLookingRightState(face, headEulerY);
        break;
      case LivenessState.lookingStraight:
        await _handleLookingStraightState(face);
        break;
      default:
        break;
    }
  }

  Future<void> _handleInitialState(Face face, double headEulerY) async {
    if (_isFaceCentered(face) && headEulerY.abs() < config.straightThreshold) {
      _steadyFrameCount++;
      if (_steadyFrameCount >= requiredSteadyFrames) {
        _updateState(LivenessState.lookingLeft);
        _steadyFrameCount = 0;
        _lastValidAngle = null;
      }
    } else {
      _steadyFrameCount = 0;
    }
  }

  Future<void> _handleLookingLeftState(Face face, double headEulerY) async {
    final threshold = config.turnThreshold;
    final targetAngle = isFrontCamera ? -threshold : threshold;

    // Check if head has turned left enough and held position
    if ((isFrontCamera && headEulerY > targetAngle) ||
        (!isFrontCamera && headEulerY < targetAngle)) {
      if (_lastValidAngle != null &&
          DateTime.now().difference(_lastValidAngle!) >= angleStabilityTime) {
        _steadyFrameCount++;
        if (_steadyFrameCount >= requiredSteadyFrames && !_hasCompletedLeft) {
          _hasCompletedLeft = true;
          _updateState(LivenessState.lookingRight);
          _steadyFrameCount = 0;
          _lastValidAngle = null;
        }
      }
    } else {
      _steadyFrameCount = 0;
      _lastValidAngle = null;
    }
  }

  Future<void> _handleLookingRightState(Face face, double headEulerY) async {
    final threshold = config.turnThreshold;
    final targetAngle = isFrontCamera ? threshold : -threshold;

    // Check if head has turned right enough and held position
    if ((isFrontCamera && headEulerY < targetAngle) ||
        (!isFrontCamera && headEulerY > targetAngle)) {
      if (_lastValidAngle != null &&
          DateTime.now().difference(_lastValidAngle!) >= angleStabilityTime) {
        _steadyFrameCount++;
        if (_steadyFrameCount >= requiredSteadyFrames && !_hasCompletedRight) {
          _hasCompletedRight = true;
          _updateState(LivenessState.lookingStraight);
          _steadyFrameCount = 0;
          _lastValidAngle = null;
        }
      }
    } else {
      _steadyFrameCount = 0;
      _lastValidAngle = null;
    }
  }

  Future<void> _handleLookingStraightState(Face face) async {
    if (_isFaceCentered(face)) {
      _steadyFrameCount++;
      if (_steadyFrameCount >= requiredSteadyFrames) {
        _updateState(LivenessState.complete);
      }
    } else {
      _steadyFrameCount = 0;
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
    _steadyFrameCount = 0;
    _hasCompletedLeft = false;
    _hasCompletedRight = false;
    _consecutiveErrors = 0;
    _lastErrorTime = null;
    _stateStartTime = null;
    _lastStateChange = null;
    _lastValidAngle = null;
    _lastEulerY = 0.0;
    _updateState(LivenessState.initial);
  }

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    _lastStateChange = DateTime.now();

    onStateChanged(
      newState,
      _calculateProgress(newState),
      _getMessageForState(newState),
      _getAnimationForState(newState),
    );
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
    return switch (state) {
      LivenessState.initial => 'assets/animations/face_scan_init.json',
      LivenessState.lookingLeft => isFrontCamera
          ? 'assets/animations/look_left.json'
          : 'assets/animations/look_right.json',
      LivenessState.lookingRight => isFrontCamera
          ? 'assets/animations/look_right.json'
          : 'assets/animations/look_left.json',
      LivenessState.lookingStraight => 'assets/animations/look_straight.json',
      LivenessState.complete => 'assets/animations/face_success.json',
      LivenessState.multipleFaces => 'assets/animations/multiple_faces.json',
    };
  }

  void dispose() {
    _faceDetector.close();
  }
}
