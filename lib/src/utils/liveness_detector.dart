import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  // Core configuration and callbacks
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;
  final bool isFrontCamera;

  // Face detection components
  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  bool _isDisposed = false;

  // State tracking
  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  // Error tracking
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;

  // Time tracking
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  double _lastEulerY = 0.0;

  // State progress tracking
  final Map<LivenessState, double> _stateProgress = {
    LivenessState.initial: 0.0,
    LivenessState.lookingLeft: 0.0,
    LivenessState.lookingRight: 0.0,
    LivenessState.lookingStraight: 0.0,
  };

  // Spoof detection tracking
  double? _lastBlinkScore;
  DateTime? _lastBlinkTime;
  List<double>? _lastFaceContours;
  DateTime? _lastContourCheck;
  int _staticFrameCount = 0;

  // Constants for spoof detection
  static const double _minBlinkThreshold = 0.1;
  static const double _maxBlinkThreshold = 0.85;
  static const Duration _contourCheckInterval = Duration(milliseconds: 300);
  static const double _contourVariationThreshold = 0.015;
  static const int _maxStaticFrames = 15;
  static const Duration _blinkTimeout = Duration(seconds: 4);

  // Constructor
  LivenessDetector({
    required this.config,
    required this.onStateChanged,
    required this.isFrontCamera,
  }) {
    _initializeFaceDetector();
    _updateState(LivenessState.initial);
  }

  // Calculate total progress across all states
  double get totalProgress {
    double total = 0.0;
    if (_stateProgress[LivenessState.initial]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingLeft]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingRight]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingStraight]! >= 1.0) total += 0.25;
    return total;
  }

  // Initialize the face detector with required options
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

  // Convert camera image to ML Kit input format
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

  // Main image processing function
  Future<void> processImage(CameraImage image) async {
    if (_isProcessing ||
        _currentState == LivenessState.complete ||
        _isDisposed) {
      return;
    }
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

  // Verify if the detected face is real (anti-spoofing)
  bool _isRealFace(Face face) {
    final now = DateTime.now();
    bool isLikelyReal = true;

    // Blink detection
    if (face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null) {
      final blinkScore =
          (face.leftEyeOpenProbability! + face.rightEyeOpenProbability!) / 2;

      // Initial blink check
      if (_lastBlinkTime == null && blinkScore < _maxBlinkThreshold) {
        _lastBlinkTime = now;
      }

      // Continuous blink monitoring
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

    // Face contour variation check
    if (_lastContourCheck == null ||
        now.difference(_lastContourCheck!) >= _contourCheckInterval) {
      final faceContour = face.contours[FaceContourType.face]?.points;
      if (faceContour != null && faceContour.isNotEmpty) {
        final currentContours =
            faceContour.map((point) => (point.x + point.y).toDouble()).toList();

        if (_lastFaceContours != null &&
            _lastFaceContours!.length == currentContours.length) {
          final variations = List.generate(
            currentContours.length,
            (i) => (currentContours[i] - _lastFaceContours![i]).abs(),
          );

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

        _lastFaceContours = currentContours;
        _lastContourCheck = now;
      }
    }

    // Final checks
    final hasRecentBlink = _lastBlinkTime != null &&
        now.difference(_lastBlinkTime!) < _blinkTimeout;
    final isExcessivelyStatic = _staticFrameCount > _maxStaticFrames * 2;

    if (!hasRecentBlink || isExcessivelyStatic) {
      isLikelyReal = false;
    }

    return isLikelyReal;
  }

  // Process a single detected face
  Future<void> _processDetectedFace(Face face) async {
    if (!_isRealFace(face)) {
      _handleSpoofingAttempt();
      return;
    }

    var headEulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      headEulerY = -headEulerY;
    }

    final now = DateTime.now();
    _stateStartTime ??= now;

    if ((_lastEulerY - headEulerY).abs() > config.straightThreshold) {
      _lastValidAngle = now;
      _staticFrameCount = 0;
    }
    _lastEulerY = headEulerY;

    // Update progress for current state
    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _stateProgress[LivenessState.initial] =
              (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
        }
        break;
      case LivenessState.lookingLeft:
        if (_isValidLeftTurn(headEulerY)) {
          _stateProgress[LivenessState.lookingLeft] =
              (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
        }
        break;
      case LivenessState.lookingRight:
        if (_isValidRightTurn(headEulerY)) {
          _stateProgress[LivenessState.lookingRight] =
              (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
        }
        break;
      case LivenessState.lookingStraight:
        if (_isFaceCentered(face)) {
          _stateProgress[LivenessState.lookingStraight] =
              (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
        }
        break;
      default:
        break;
    }

    if (_lastStateChange != null &&
        now.difference(_lastStateChange!) < config.phaseDuration) {
      return;
    }

    // Handle state-specific processing
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

  // Handle initial state detection
  Future<void> _handleInitialState(Face face, double headEulerY) async {
    if (_isFaceCentered(face) && headEulerY.abs() < config.straightThreshold) {
      _stableFrameCount++;
      if (_stableFrameCount >= config.requiredFrames) {
        _updateState(LivenessState.lookingLeft);
        _stableFrameCount = 0;
        _lastValidAngle = null;
      }
    } else {
      _stableFrameCount = 0;
    }
  }

  // Handle left-looking state
  Future<void> _handleLookingLeftState(Face face, double headEulerY) async {
    if (_isValidLeftTurn(headEulerY)) {
      if (_lastValidAngle != null &&
          DateTime.now().difference(_lastValidAngle!) >= config.phaseDuration) {
        _stableFrameCount++;
        if (_stableFrameCount >= config.requiredFrames && !_hasCompletedLeft) {
          _hasCompletedLeft = true;
          _updateState(LivenessState.lookingRight);
          _stableFrameCount = 0;
          _lastValidAngle = null;
        }
      }
    } else {
      _stableFrameCount = 0;
      _lastValidAngle = null;
    }
  }

  // Handle right-looking state
  Future<void> _handleLookingRightState(Face face, double headEulerY) async {
    if (_isValidRightTurn(headEulerY)) {
      if (_lastValidAngle != null &&
          DateTime.now().difference(_lastValidAngle!) >= config.phaseDuration) {
        _stableFrameCount++;
        if (_stableFrameCount >= config.requiredFrames && !_hasCompletedRight) {
          _hasCompletedRight = true;
          _updateState(LivenessState.lookingStraight);
          _stableFrameCount = 0;
          _lastValidAngle = null;
        }
      }
    } else {
      _stableFrameCount = 0;
      _lastValidAngle = null;
    }
  }

  // Handle straight-looking state
  Future<void> _handleLookingStraightState(Face face) async {
    if (_isFaceCentered(face)) {
      _stableFrameCount++;
      if (_stableFrameCount >= config.requiredFrames) {
        _updateState(LivenessState.complete);
      }
    } else {
      _stableFrameCount = 0;
    }
  }

  // Check if face is looking left correctly
  bool _isValidLeftTurn(double headEulerY) {
    final targetAngle =
        isFrontCamera ? config.turnThreshold : config.turnThreshold;
    return (isFrontCamera && headEulerY >= targetAngle) ||
        (!isFrontCamera && headEulerY <= targetAngle);
  }

  // Check if face is looking right correctly
  bool _isValidRightTurn(double headEulerY) {
    final targetAngle =
        isFrontCamera ? -config.turnThreshold : -config.turnThreshold;
    return (isFrontCamera && headEulerY <= targetAngle) ||
        (!isFrontCamera && headEulerY >= targetAngle);
  }

  // Check if face is centered and aligned
  bool _isFaceCentered(Face face) {
    var eulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      eulerY = -eulerY;
    }
    final eulerZ = face.headEulerAngleZ ?? 0.0;

    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  // Handle when no face is detected
  void _handleNoFace() {
    if (_currentState != LivenessState.initial) {
      _updateState(LivenessState.initial);
    }
    _incrementErrorCount();
  }

  // Handle when multiple faces are detected
  void _handleMultipleFaces() {
    _resetProgress();
    _updateState(LivenessState.multipleFaces);
    _incrementErrorCount();
  }

  // Handle potential spoofing attempts
  void _handleSpoofingAttempt() {
    _resetProgress();
    onStateChanged(
      LivenessState.initial,
      0.0,
      "Please use a real face",
      _getCurrentStateInstructions(),
    );
    _incrementErrorCount();
  }

  // Handle errors in face detection
  void _handleError() {
    _incrementErrorCount();
    if (_consecutiveErrors > config.maxConsecutiveErrors) {
      _resetProgress();
      _updateState(LivenessState.failed);
    }
  }

  // Increment error count with timing logic
  void _incrementErrorCount() {
    final now = DateTime.now();
    if (_lastErrorTime != null &&
        now.difference(_lastErrorTime!) > config.errorResetDuration) {
      _consecutiveErrors = 0;
    }
    _consecutiveErrors++;
    _lastErrorTime = now;
  }

  // Reset all progress tracking
  void _resetProgress() {
    _stableFrameCount = 0;
    _hasCompletedLeft = false;
    _hasCompletedRight = false;
    _lastValidAngle = null;
    _stateStartTime = null;
    _lastStateChange = null;
    _staticFrameCount = 0;

    // Reset all state progress
    for (var state in _stateProgress.keys) {
      _stateProgress[state] = 0.0;
    }
  }

  // Update current state and notify listeners
  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    _lastStateChange = DateTime.now();
    _stableFrameCount = 0;

    onStateChanged(
      newState,
      totalProgress,
      _getStateMessage(newState),
      _getCurrentStateInstructions(),
    );
  }

  // Get message for current state
  String _getStateMessage(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return "Position your face in the frame";
      case LivenessState.lookingLeft:
        return "Turn your head left";
      case LivenessState.lookingRight:
        return "Turn your head right";
      case LivenessState.lookingStraight:
        return "Look straight ahead";
      case LivenessState.complete:
        return "Verification complete";
      case LivenessState.multipleFaces:
        return "Multiple faces detected";
      case LivenessState.failed:
        return "Error during verification";
      default:
        return "";
    }
  }

  // Get detailed instructions for current state
  String _getCurrentStateInstructions() {
    switch (_currentState) {
      case LivenessState.initial:
        return "Center your face in the frame and look straight ahead";
      case LivenessState.lookingLeft:
        return "Slowly turn your head to the left";
      case LivenessState.lookingRight:
        return "Slowly turn your head to the right";
      case LivenessState.lookingStraight:
        return "Return to looking straight ahead";
      case LivenessState.complete:
        return "Liveness verification completed successfully";
      case LivenessState.multipleFaces:
        return "Please ensure only one face is visible";
      case LivenessState.failed:
        return "Please try again";
      default:
        return "";
    }
  }

  // Clean up resources
  void dispose() {
    _isDisposed = true;
    _faceDetector.close();
  }
}
