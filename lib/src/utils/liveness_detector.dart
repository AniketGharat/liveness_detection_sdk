// liveness_detector.dart
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String, String) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  int _stableFrameCount = 0;
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;
  bool _hasCompletedLeft = false;
  bool _hasCompletedRight = false;

  LivenessDetector({
    required this.config,
    required this.onStateChanged,
  }) {
    _initializeFaceDetector();
  }

  void _initializeFaceDetector() {
    final options = FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true, // Enable face tracking
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
      rotation: InputImageRotation
          .rotation270deg, // Adjust based on device orientation
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
    final headEulerY = face.headEulerAngleY ?? 0.0;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _updateState(LivenessState.lookingLeft);
        }
        break;

      case LivenessState.lookingLeft:
        if (headEulerY < -config.turnThreshold && !_hasCompletedLeft) {
          _hasCompletedLeft = true;
          _updateState(LivenessState.lookingRight);
        }
        break;

      case LivenessState.lookingRight:
        if (headEulerY > config.turnThreshold && !_hasCompletedRight) {
          _hasCompletedRight = true;
          _updateState(LivenessState.lookingStraight);
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
    final eulerY = face.headEulerAngleY ?? 0.0;
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

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    final progress = switch (newState) {
      LivenessState.initial => 0.0,
      LivenessState.lookingLeft => 0.25,
      LivenessState.lookingRight => 0.5,
      LivenessState.lookingStraight => 0.75,
      LivenessState.complete => 1.0,
      LivenessState.multipleFaces => 0.0,
    };

    onStateChanged(
      newState,
      progress,
      _getMessageForState(newState),
      _getAnimationForState(newState),
    );
  }

  String _getMessageForState(LivenessState state) {
    return switch (state) {
      LivenessState.initial => "Position your face in the circle",
      LivenessState.lookingLeft => "Turn your head left slowly",
      LivenessState.lookingRight => "Turn your head right slowly",
      LivenessState.lookingStraight => "Look straight ahead",
      LivenessState.complete => "Perfect! Processing...",
      LivenessState.multipleFaces => "Only one face should be visible",
    };
  }

  String _getAnimationForState(LivenessState state) {
    return switch (state) {
      LivenessState.initial =>
        'packages/liveness_detection_sdk/assets/animations/face_scan.json',
      LivenessState.lookingLeft =>
        'packages/liveness_detection_sdk/assets/animations/look_left.json',
      LivenessState.lookingRight =>
        'packages/liveness_detection_sdk/assets/animations/look_right.json',
      LivenessState.lookingStraight =>
        'packages/liveness_detection_sdk/assets/animations/look_straight.json',
      LivenessState.complete =>
        'packages/liveness_detection_sdk/assets/animations/success.json',
      LivenessState.multipleFaces =>
        'packages/liveness_detection_sdk/assets/animations/multiple_faces.json',
    };
  }

  void dispose() {
    _faceDetector.close();
  }
}
