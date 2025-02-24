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
  bool _isDisposed = false;

  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  DateTime? _stateStartTime;
  DateTime? _lastStateChange;
  DateTime? _lastValidAngle;
  double _lastEulerY = 0.0;

  final Map<LivenessState, double> _stateProgress = {
    LivenessState.initial: 0.0,
    LivenessState.lookingLeft: 0.0,
    LivenessState.lookingRight: 0.0,
    LivenessState.lookingStraight: 0.0,
  };

  // Constructor and initialization
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

  // Main processing functions
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

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    // Corrected rotation handling for both cameras
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

  // Face processing logic
  Future<void> _processDetectedFace(Face face) async {
    // Get raw euler Y angle
    double rawEulerY = face.headEulerAngleY ?? 0.0;

    // Apply camera-specific transformations
    double headEulerY = isFrontCamera ? rawEulerY : -rawEulerY;

    final now = DateTime.now();
    _stateStartTime ??= now;

    // Update angle tracking
    if ((_lastEulerY - headEulerY).abs() > config.straightThreshold) {
      _lastValidAngle = now;
    }
    _lastEulerY = headEulerY;

    // Update state progress
    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceStraight(headEulerY)) {
          _updateStateProgress(LivenessState.initial);
        }
        break;
      case LivenessState.lookingLeft:
        if (_isValidLeftTurn(headEulerY)) {
          _updateStateProgress(LivenessState.lookingLeft);
        }
        break;
      case LivenessState.lookingRight:
        if (_isValidRightTurn(headEulerY)) {
          _updateStateProgress(LivenessState.lookingRight);
        }
        break;
      case LivenessState.lookingStraight:
        if (_isFaceStraight(headEulerY)) {
          _updateStateProgress(LivenessState.lookingStraight);
        }
        break;
      default:
        break;
    }

    // Process current state
    await _processCurrentState(face, headEulerY);
  }

  Future<void> _processCurrentState(Face face, double headEulerY) async {
    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceStraight(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (_isValidLeftTurn(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _hasCompletedLeft = true;
            _updateState(LivenessState.lookingRight);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_isValidRightTurn(headEulerY)) {
          _stableFrameCount++;
          if (_stableFrameCount >= config.requiredFrames) {
            _hasCompletedRight = true;
            _updateState(LivenessState.lookingStraight);
            _resetStateTracking();
          }
        } else {
          _stableFrameCount = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (_isFaceStraight(headEulerY)) {
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

  // Angle validation functions
  bool _isValidLeftTurn(double headEulerY) {
    final threshold =
        isFrontCamera ? config.turnThreshold : -config.turnThreshold;
    return isFrontCamera ? headEulerY >= threshold : headEulerY <= threshold;
  }

  bool _isValidRightTurn(double headEulerY) {
    final threshold =
        isFrontCamera ? -config.turnThreshold : config.turnThreshold;
    return isFrontCamera ? headEulerY <= threshold : headEulerY >= threshold;
  }

  bool _isFaceStraight(double headEulerY) {
    return headEulerY.abs() < config.straightThreshold;
  }

  // State management
  void _updateStateProgress(LivenessState state) {
    _stateProgress[state] =
        (_stableFrameCount / config.requiredFrames).clamp(0.0, 1.0);
  }

  void _resetStateTracking() {
    _stableFrameCount = 0;
    _lastValidAngle = null;
  }

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    _lastStateChange = DateTime.now();
    _stableFrameCount = 0;

    // Update state progress cumulatively based on state progression
    switch (newState) {
      case LivenessState.initial:
        _stateProgress[LivenessState.initial] = 1.0;
        break;
      case LivenessState.lookingLeft:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        break;
      case LivenessState.lookingRight:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        _stateProgress[LivenessState.lookingRight] = 1.0;
        break;
      case LivenessState.lookingStraight:
        _stateProgress[LivenessState.initial] = 1.0;
        _stateProgress[LivenessState.lookingLeft] = 1.0;
        _stateProgress[LivenessState.lookingRight] = 1.0;
        _stateProgress[LivenessState.lookingStraight] = 1.0;
        break;
      case LivenessState.complete:
        // Mark all states as complete
        _stateProgress.forEach((state, _) {
          _stateProgress[state] = 1.0;
        });
        break;
      case LivenessState.failed:
      case LivenessState.multipleFaces:
        // Reset progress for error states
        _stateProgress.forEach((state, _) {
          _stateProgress[state] = 0.0;
        });
        break;
    }

    onStateChanged(
      newState,
      calculateTotalProgress(),
      _getStateMessage(newState),
      _getCurrentStateInstructions(),
    );
  }

  double calculateTotalProgress() {
    if (_currentState == LivenessState.failed ||
        _currentState == LivenessState.multipleFaces) {
      return 0.0;
    }

    // Calculate progress based on completed states
    double total = 0.0;
    if (_stateProgress[LivenessState.initial]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingLeft]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingRight]! >= 1.0) total += 0.25;
    if (_stateProgress[LivenessState.lookingStraight]! >= 1.0) total += 0.25;
    return total;
  }

  // Error handling
  void _handleNoFace() {
    if (_currentState != LivenessState.initial) {
      _updateState(LivenessState.initial);
    }
    _incrementErrorCount();
  }

  void _handleMultipleFaces() {
    _resetProgress();
    _updateState(LivenessState.multipleFaces);
    _incrementErrorCount();
  }

  void _handleError() {
    _incrementErrorCount();
    if (_consecutiveErrors > config.maxConsecutiveErrors) {
      _resetProgress();
      _updateState(LivenessState.failed);
    }
  }

  void _incrementErrorCount() {
    final now = DateTime.now();
    if (_lastErrorTime != null &&
        now.difference(_lastErrorTime!) > config.errorResetDuration) {
      _consecutiveErrors = 0;
    }
    _consecutiveErrors++;
    _lastErrorTime = now;
  }

  void _resetProgress() {
    _stableFrameCount = 0;
    _hasCompletedLeft = false;
    _hasCompletedRight = false;
    _lastValidAngle = null;
    _stateStartTime = null;
    _lastStateChange = null;

    for (var state in _stateProgress.keys) {
      _stateProgress[state] = 0.0;
    }
  }

  // Helper functions
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
        return "Verification failed";
      default:
        return "";
    }
  }

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

  void dispose() {
    _isDisposed = true;
    _faceDetector.close();
  }
}
