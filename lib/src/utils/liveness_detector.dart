import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  // Core configuration and callback
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;
  final bool isFrontCamera;

  // Face detection components
  late final FaceDetector _faceDetector;
  bool _isProcessing = false;

  // State tracking
  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  // Timing management
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  int _steadyFrameCount = 0;
  double _lastEulerY = 0.0;

  // Spoof detection fields
  double? _lastBlinkScore;
  DateTime? _lastBlinkTime;
  List<double>? _lastFaceContours;
  DateTime? _lastContourCheck;
  int _staticFrameCount = 0;

  // Constants for validation
  static const int requiredSteadyFrames = 12; // Reduced from 15
  static const Duration minStateTime =
      Duration(milliseconds: 800); // Reduced from 1000
  static const Duration angleStabilityTime =
      Duration(milliseconds: 400); // Reduced from 500
  static const double angleChangeTolerance = 3.0; // Reduced from 5.0

  // Constants for spoof detection
  static const double _minBlinkThreshold = 0.05;
  static const double _maxBlinkThreshold = 0.9;
  static const Duration _contourCheckInterval = Duration(milliseconds: 400);
  static const double _contourVariationThreshold = 0.01;
  static const int _maxStaticFrames = 20;
  static const Duration _blinkTimeout = Duration(seconds: 5);

  // Constructor
  LivenessDetector({
    required this.config,
    required this.onStateChanged,
    required this.isFrontCamera,
  }) {
    _initializeFaceDetector();
    _updateState(LivenessState.initial);
  }

  // Initialize face detector
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

  // Convert camera image to ML Kit format
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

  // Main processing pipeline
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
      debugPrint('Error in processImage: $e');
      _handleError();
    } finally {
      _isProcessing = false;
    }
  }

  // Process a single detected face
  Future<void> _processDetectedFace(Face face) async {
    if (!_isRealFace(face)) {
      debugPrint('Spoof detection triggered - not a real face');
      _handleSpoofingAttempt();
      return;
    }

    if (_currentState == LivenessState.multipleFaces) {
      _resetProgress();
    }

    var headEulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      headEulerY = -headEulerY;
    }

    final now = DateTime.now();
    _stateStartTime ??= now;

    if ((_lastEulerY - headEulerY).abs() > angleChangeTolerance) {
      _lastValidAngle = now;
      _steadyFrameCount = 0;
      _staticFrameCount = 0;
    } else {
      _staticFrameCount++;
    }
    _lastEulerY = headEulerY;

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

  // Improved spoof detection
  bool _isRealFace(Face face) {
    final now = DateTime.now();
    bool isLikelyReal = true;

    // Blink detection
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      final blinkScore =
          (face.leftEyeOpenProbability! + face.rightEyeOpenProbability!) / 2;

      if (_lastBlinkScore != null) {
        final blinkDelta = (_lastBlinkScore! - blinkScore).abs();
        if (blinkDelta > _minBlinkThreshold &&
            blinkScore < _maxBlinkThreshold) {
          _lastBlinkTime = now;
          _staticFrameCount = 0;
        }
      }
      _lastBlinkScore = blinkScore;
    }

    // Contour variation check
    if (_lastContourCheck == null ||
        now.difference(_lastContourCheck!) >= _contourCheckInterval) {
      final faceContour = face.contours[FaceContourType.face]?.points;
      if (faceContour != null && faceContour.isNotEmpty) {
        final currentContours =
            faceContour.map((point) => (point.x + point.y)).toList();

        if (_lastFaceContours != null &&
            _lastFaceContours!.length == currentContours.length) {
          final variations = List.generate(currentContours.length,
              (i) => (currentContours[i] - _lastFaceContours![i]).abs());

          final averageVariation = variations.isNotEmpty
              ? variations.reduce((a, b) => a + b) / variations.length
              : 0.0;

          if (averageVariation < _contourVariationThreshold) {
            _staticFrameCount++;
          } else {
            _staticFrameCount =
                (_staticFrameCount - 1).clamp(0, _maxStaticFrames);
          }
        }

        _lastFaceContours = currentContours.cast<double>();
        _lastContourCheck = now;
      }
    }

    final hasRecentBlink = _lastBlinkTime != null &&
        now.difference(_lastBlinkTime!) < _blinkTimeout;
    final isExcessivelyStatic = _staticFrameCount > _maxStaticFrames;

    if (!hasRecentBlink && isExcessivelyStatic) {
      isLikelyReal = false;
    }

    debugPrint(
        'Liveness Stats - Blink: $hasRecentBlink, Static: $_staticFrameCount, Real: $isLikelyReal');
    return isLikelyReal;
  }

  // Handle initial face positioning
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

  // Handle left turn state
  Future<void> _handleLookingLeftState(Face face, double headEulerY) async {
    final threshold = config.turnThreshold;
    final targetAngle = isFrontCamera ? -threshold : threshold;

    if ((isFrontCamera && headEulerY <= targetAngle) ||
        (!isFrontCamera && headEulerY >= targetAngle)) {
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

  // Handle right turn state
  Future<void> _handleLookingRightState(Face face, double headEulerY) async {
    final threshold = config.turnThreshold;
    final targetAngle = isFrontCamera ? threshold : -threshold;

    if ((isFrontCamera && headEulerY >= targetAngle) ||
        (!isFrontCamera && headEulerY <= targetAngle)) {
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

  // Handle final straight look state
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

  // Check if face is centered
  bool _isFaceCentered(Face face) {
    var eulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      eulerY = -eulerY;
    }
    final eulerZ = face.headEulerAngleZ ?? 0.0;

    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  // Handle no face detected
  void _handleNoFace() {
    if (_currentState != LivenessState.initial) {
      _updateState(LivenessState.initial);
    }
    _incrementErrorCount();
  }

  // Handle multiple faces
  void _handleMultipleFaces() {
    if (_currentState != LivenessState.multipleFaces) {
      _updateState(LivenessState.multipleFaces);
    }
    _incrementErrorCount();
  }

  // Handle spoofing attempt
  void _handleSpoofingAttempt() {
    _resetProgress();
    onStateChanged(
      LivenessState.initial,
      0.0,
      "Please use a real face for verification",
      _getAnimationForState(LivenessState.initial),
    );
  }

  // Handle errors
  void _handleError() {
    _incrementErrorCount();
    debugPrint('Error handled: $_consecutiveErrors consecutive errors');
  }

  // Error counting
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

  // Reset all progress
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
    _staticFrameCount = 0;
    _lastBlinkScore = null;
    _lastBlinkTime = null;
    _lastFaceContours = null;
    _lastContourCheck = null;
    _updateState(LivenessState.initial);
  }

  // Update state
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

  // Calculate progress percentage
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

  // Get user instruction message for current state
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

  // Get animation path for current state
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

  // Clean up resources
  void dispose() {
    _faceDetector.close();
  }
}
