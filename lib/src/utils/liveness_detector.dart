import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  // Core configuration
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
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  // Time tracking
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  double _lastEulerY = 0.0;

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
    if (_isProcessing || _currentState == LivenessState.complete || _isDisposed)
      return;
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

  bool _isRealFace(Face face) {
    final now = DateTime.now();
    bool isLikelyReal = true;

    // Initial blink check
    if (_lastBlinkTime == null) {
      if (face.leftEyeOpenProbability != null &&
          face.rightEyeOpenProbability != null) {
        final blinkScore =
            (face.leftEyeOpenProbability! + face.rightEyeOpenProbability!) / 2;
        if (blinkScore < _maxBlinkThreshold) {
          _lastBlinkTime = now;
        } else {
          return false;
        }
      }
    }

    // Continuous blink detection
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

    final hasRecentBlink = _lastBlinkTime != null &&
        now.difference(_lastBlinkTime!) < _blinkTimeout;
    final isExcessivelyStatic = _staticFrameCount > _maxStaticFrames * 2;

    if (!hasRecentBlink || isExcessivelyStatic) {
      isLikelyReal = false;
    }

    return isLikelyReal;
  }

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

    if (_lastStateChange != null &&
        now.difference(_lastStateChange!) < config.phaseDuration) {
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

  Future<void> _handleLookingLeftState(Face face, double headEulerY) async {
    final targetAngle =
        isFrontCamera ? -config.turnThreshold : config.turnThreshold;

    if ((isFrontCamera && headEulerY >= targetAngle) ||
        (!isFrontCamera && headEulerY <= targetAngle)) {
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

  Future<void> _handleLookingRightState(Face face, double headEulerY) async {
    final targetAngle =
        isFrontCamera ? config.turnThreshold : -config.turnThreshold;

    if ((isFrontCamera && headEulerY <= targetAngle) ||
        (!isFrontCamera && headEulerY >= targetAngle)) {
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

  bool _isFaceCentered(Face face) {
    var eulerY = face.headEulerAngleY ?? 0.0;
    if (!isFrontCamera) {
      eulerY = -eulerY;
    }
    final eulerZ = face.headEulerAngleZ ?? 0.0;

    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  // Add dispose method
  Future<void> dispose() async {
    _isDisposed = true;
    await _faceDetector.close();
  }

  void _handleNoFace() {
    if (_currentState != LivenessState.initial) {
      _updateState(LivenessState.initial);
    }
    _incrementErrorCount();
  }

  void _handleMultipleFaces() {
    if (_currentState != LivenessState.multipleFaces) {
      _updateState(LivenessState.multipleFaces);
    }
    _incrementErrorCount();
  }

  void _handleSpoofingAttempt() {
    _resetProgress();
    onStateChanged(
      LivenessState.initial,
      0.0,
      "Please position your face properly",
      _getAnimationForState(LivenessState.initial),
    );
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
    if (_isDisposed) return;

    _stableFrameCount = 0;
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
  }

  void _updateState(LivenessState state) {
    if (_isDisposed) return;

    _currentState = state;
    _lastStateChange = DateTime.now();
    onStateChanged(
      state,
      _stableFrameCount.toDouble(),
      _getStateMessage(state),
      _getAnimationForState(state),
    );
  }

  String _getStateMessage(LivenessState state) {
    switch (state) {
      case LivenessState.lookingLeft:
        return "Please look left";
      case LivenessState.lookingRight:
        return "Please look right";
      case LivenessState.lookingStraight:
        return "Please look straight";
      case LivenessState.complete:
        return "Liveness check complete!";
      case LivenessState.initial:
      default:
        return "Please look at the camera";
    }
  }

  String _getAnimationForState(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'assets/animations/face_scan_init.json';
      case LivenessState.lookingLeft:
        return 'assets/animations/look_left.json';
      case LivenessState.lookingRight:
        return 'assets/animations/look_right.json';
      case LivenessState.lookingStraight:
        return 'assets/animations/look_straight.json';
      case LivenessState.complete:
        return 'assets/animations/face_success.json';
      case LivenessState.multipleFaces:
        return 'assets/animations/multiple_faces.json';
      default:
        return 'assets/animations/face_scan_init.json';
    }
  }
}
