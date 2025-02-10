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
  int _requiredFramesCount = 0;
  int _stableFrameCount = 0;
  DateTime? _lastErrorTime;
  int _consecutiveErrors = 0;

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
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    );
    _faceDetector = FaceDetector(options: options);
  }

  String _getAnimationPath(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 'assets/animations/face_scan.json';
      case LivenessState.lookingStraight:
        return 'assets/animations/look_straight.json';
      case LivenessState.lookingLeft:
        return 'assets/animations/turn_left.json';
      case LivenessState.lookingRight:
        return 'assets/animations/turn_right.json';
      case LivenessState.complete:
        return 'assets/animations/success.json';
      case LivenessState.multipleFaces:
        return 'assets/animations/multiple_faces.json';
    }
  }

  String _getStateMessage(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return "Position your face in the circle";
      case LivenessState.lookingStraight:
        return "Look straight ahead";
      case LivenessState.lookingLeft:
        return "Turn your head left slowly";
      case LivenessState.lookingRight:
        return "Turn your head right slowly";
      case LivenessState.complete:
        return "Perfect! Processing...";
      case LivenessState.multipleFaces:
        return "Only one face should be visible";
    }
  }

  void _updateState(LivenessState newState) {
    if (_currentState == newState) return;

    _currentState = newState;
    final progress = _getStateProgress(newState);
    final message = _getStateMessage(newState);
    final animation = _getAnimationPath(newState);

    _requiredFramesCount = 0;
    _stableFrameCount = 0;
    onStateChanged(newState, progress, message, animation);
  }

  double _getStateProgress(LivenessState state) {
    switch (state) {
      case LivenessState.initial:
        return 0.0;
      case LivenessState.lookingStraight:
        return 0.25;
      case LivenessState.lookingLeft:
        return 0.5;
      case LivenessState.lookingRight:
        return 0.75;
      case LivenessState.complete:
        return 1.0;
      case LivenessState.multipleFaces:
        return 0.0;
    }
  }

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _handleNoFace();
        return;
      }
      if (faces.length > 1) {
        _handleMultipleFaces();
        return;
      }

      final face = faces.first;
      await _processDetectedFace(face);
      _resetErrorCount();
    } catch (e) {
      print('Error processing image: $e');
      _incrementErrorCount();
    } finally {
      _isProcessing = false;
    }
  }

  void _handleNoFace() {
    _updateState(LivenessState.initial);
    _incrementErrorCount();
  }

  void _handleMultipleFaces() {
    _updateState(LivenessState.multipleFaces);
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
  }

  void _resetErrorCount() {
    _consecutiveErrors = 0;
    _lastErrorTime = null;
  }

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }

    final bytes = allBytes.done().buffer.asUint8List();
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Future<void> _processDetectedFace(Face face) async {
    final headEulerY = face.headEulerAngleY ?? 0.0;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceStraight(face)) {
          _incrementStableFrames(() {
            _updateState(LivenessState.lookingStraight);
          });
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingStraight:
        if (headEulerY < -config.turnThreshold) {
          _incrementStableFrames(() {
            _updateState(LivenessState.lookingLeft);
          });
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingLeft:
        if (headEulerY > config.turnThreshold) {
          _incrementStableFrames(() {
            _updateState(LivenessState.lookingRight);
          });
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceStraight(face)) {
          _incrementStableFrames(() {
            _updateState(LivenessState.complete);
          });
        } else {
          _resetProgress();
        }
        break;

      default:
        break;
    }
  }

  bool _isFaceStraight(Face face) {
    final eulerY = face.headEulerAngleY ?? 0.0;
    final eulerZ = face.headEulerAngleZ ?? 0.0;
    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  void _incrementStableFrames(VoidCallback onComplete) {
    _stableFrameCount++;
    if (_stableFrameCount >= 10) {
      _requiredFramesCount++;
      if (_requiredFramesCount >= config.requiredFrames) {
        onComplete();
      }
    }
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
    _stableFrameCount = 0;
  }

  void dispose() {
    _faceDetector.close();
  }
}
