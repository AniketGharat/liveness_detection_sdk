import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:liveness_detection_sdk/src/models/liveness_result.dart';
import 'package:liveness_detection_sdk/src/models/liveness_state.dart';

import '../models/liveness_config.dart';
import 'face_utils.dart';

class LivenessDetector {
  final LivenessConfig config;

  final _resultController = StreamController<LivenessResult>.broadcast();
  final _stateController = StreamController<LivenessState>.broadcast();
  final _processingController = StreamController<bool>.broadcast();

  Stream<LivenessResult> get detectionResult => _resultController.stream;
  Stream<LivenessState> get livenessState => _stateController.stream;
  Stream<bool> get isProcessing => _processingController.stream;

  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.25,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  bool _isProcessing = false;
  int _straightCounter = 0;
  int _leftCounter = 0;
  int _rightCounter = 0;
  int _straightAgainCounter = 0;
  int _blinkCounter = 0;
  DateTime _stateStartTime = DateTime.now();
  DateTime _lastErrorTime = DateTime.now();
  int _consecutiveErrorCount = 0;
  LivenessState _currentState = LivenessState.initial;

  LivenessDetector({
    this.config = const LivenessConfig(),
  });

  Future<void> processImage(
      CameraImage image, InputImageRotation rotation) async {
    if (_isProcessing) return;

    _isProcessing = true;
    _processingController.add(true);

    try {
      final inputImage = _convertCameraImageToInputImage(image, rotation);
      final faces = await _faceDetector.processImage(inputImage);
      _handleFaceDetectionResult(
          faces,
          Size(
            image.width.toDouble(),
            image.height.toDouble(),
          ));
    } catch (e) {
      _handleError('Face detection failed: $e');
    } finally {
      _isProcessing = false;
      _processingController.add(false);
    }
  }

  void _handleFaceDetectionResult(List<Face> faces, Size imageSize) {
    if (faces.isEmpty) {
      _handleError('No face detected');
      return;
    }

    if (faces.length > 1) {
      _handleError('Multiple faces detected');
      return;
    }

    final face = faces.first;
    if (!_isValidFace(face, imageSize)) {
      _handleError('Please position your face properly');
      return;
    }

    _processFace(face);
  }

  bool _isValidFace(Face face, Size imageSize) {
    final headAngleZ = face.headEulerAngleZ ?? 0;
    return FaceUtils.isFacePositionValid(face, imageSize) &&
        headAngleZ.abs() <= 20 &&
        face.trackingId != null;
  }

  void _processFace(Face face) {
    if (_currentState == LivenessState.error) return;

    final eulerY = face.headEulerAngleY ?? 0;

    switch (_currentState) {
      case LivenessState.initial:
        _processInitialState(eulerY);
        break;
      case LivenessState.lookingStraight:
        _processStraightState(eulerY);
        break;
      case LivenessState.lookingLeft:
        _processLeftState(eulerY);
        break;
      case LivenessState.lookingRight:
        _processRightState(eulerY);
        break;
      case LivenessState.lookingStraightAgain:
        _processStraightAgainState(eulerY);
        break;
      case LivenessState.blinkEyes:
        _processBlinkState(face);
        break;
      default:
        break;
    }
  }

  void _processInitialState(double eulerY) {
    if (_isLookingStraight(eulerY)) {
      _straightCounter++;
      if (_straightCounter >= config.requiredFrames) {
        _updateState(LivenessState.lookingStraight);
      }
    } else {
      _straightCounter = 0;
    }
  }

  void _processStraightState(double eulerY) {
    if (_hasCompletedState() && _isLookingLeft(eulerY)) {
      _leftCounter++;
      if (_leftCounter >= config.requiredFrames) {
        _updateState(LivenessState.lookingLeft);
      }
    } else {
      _leftCounter = 0;
    }
  }

  void _processLeftState(double eulerY) {
    if (_hasCompletedState() && _isLookingRight(eulerY)) {
      _rightCounter++;
      if (_rightCounter >= config.requiredFrames) {
        _updateState(LivenessState.lookingRight);
      }
    } else {
      _rightCounter = 0;
    }
  }

  void _processRightState(double eulerY) {
    if (_hasCompletedState() && _isLookingStraight(eulerY)) {
      _straightAgainCounter++;
      if (_straightAgainCounter >= config.requiredFrames) {
        _updateState(config.requireBlink
            ? LivenessState.blinkEyes
            : LivenessState.complete);
      }
    } else {
      _straightAgainCounter = 0;
    }
  }

  void _processStraightAgainState(double eulerY) {
    if (_hasCompletedState() && _isLookingStraight(eulerY)) {
      _updateState(LivenessState.complete);
    }
  }

  void _processBlinkState(Face face) {
    if (FaceUtils.isBlinking(face)) {
      _blinkCounter++;
      if (_blinkCounter >= config.requiredFrames) {
        _updateState(LivenessState.complete);
      }
    } else {
      _blinkCounter = 0;
    }
  }

  bool _isLookingStraight(double eulerY) =>
      eulerY.abs() <= config.straightThreshold;

  bool _isLookingLeft(double eulerY) => eulerY > config.turnThreshold;

  bool _isLookingRight(double eulerY) => eulerY < -config.turnThreshold;

  bool _hasCompletedState() =>
      DateTime.now().difference(_stateStartTime).inMilliseconds >=
      config.stateDuration;

  void _updateState(LivenessState newState) {
    _currentState = newState;
    _stateStartTime = DateTime.now();
    _stateController.add(newState);

    if (newState == LivenessState.complete) {
      _resultController.add(LivenessResult(
        isSuccess: true,
        state: newState,
        metadata: {
          'completionTime': DateTime.now().millisecondsSinceEpoch,
        },
      ));
    }
  }

  void _handleError(String message) {
    final now = DateTime.now();
    if (now.difference(_lastErrorTime) < config.errorTimeout) {
      _consecutiveErrorCount++;
      if (_consecutiveErrorCount >= config.maxConsecutiveErrors) {
        reset();
        return;
      }
    } else {
      _consecutiveErrorCount = 1;
    }

    _lastErrorTime = now;
    _updateState(LivenessState.error);
    _resultController.add(LivenessResult(
      isSuccess: false,
      errorMessage: message,
      state: LivenessState.error,
    ));
  }

  void reset() {
    _currentState = LivenessState.initial;
    _stateStartTime = DateTime.now();
    _consecutiveErrorCount = 0;
    _lastErrorTime = DateTime.now();
    _straightCounter = 0;
    _leftCounter = 0;
    _rightCounter = 0;
    _straightAgainCounter = 0;
    _blinkCounter = 0;
    _stateController.add(LivenessState.initial);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
    await _resultController.close();
    await _stateController.close();
    await _processingController.close();
  }

  InputImage _convertCameraImageToInputImage(
      CameraImage image, InputImageRotation rotation) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.bgra8888,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }
}
