import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../models/liveness_state.dart';

class LivenessDetector {
  static const String tag = 'LivenessDetector';
  static const int requiredFrames = 5;
  static const int stateDuration = 500; // milliseconds

  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.25,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  final _livenessStateController = StreamController<LivenessState>.broadcast();
  Stream<LivenessState> get livenessState => _livenessStateController.stream;

  bool _isProcessing = false;
  int _straightCounter = 0;
  int _leftCounter = 0;
  int _rightCounter = 0;
  int _straightAgainCounter = 0;
  DateTime _stateStartTime = DateTime.now();
  DateTime _lastErrorTime = DateTime.now();
  int _consecutiveErrorCount = 0;
  LivenessState _currentState = LivenessState.initial;

  Future<void> processImage(
      CameraImage image, InputImageRotation rotation) async {
    if (_isProcessing) return;

    _isProcessing = true;
    try {
      final inputImage = _convertCameraImageToInputImage(image, rotation);
      final faces = await _faceDetector.processImage(inputImage);
      _handleFaceDetectionResult(faces);
    } catch (e) {
      _handleError('Face detection failed: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _handleFaceDetectionResult(List<Face> faces) {
    if (faces.isEmpty) {
      _handleError('No face detected');
      _resetCounters();
      return;
    }

    if (faces.length > 1) {
      _handleError(
          'Multiple faces detected - Please ensure only one face is visible');
      _resetCounters();
      return;
    }

    final face = faces.first;
    if (!_isValidFace(face)) {
      _handleError('Please position your face properly within the frame');
      _resetCounters();
      return;
    }

    _processFace(face);
  }

  bool _isValidFace(Face face) {
    final headAngleZ = face.headEulerAngleZ ?? 0;
    final boundingBox = face.boundingBox;

    final isValidSize = boundingBox.width >= 100 && boundingBox.height >= 100;
    final isValidAngle = headAngleZ >= -20 && headAngleZ <= 20;
    final isTracked = face.trackingId != null;

    return isValidSize && isValidAngle && isTracked;
  }

  void _processFace(Face face) {
    final eulerY = face.headEulerAngleY ?? 0;

    if (_currentState == LivenessState.error) return;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isLookingStraight(eulerY)) {
          _straightCounter++;
          if (_straightCounter >= requiredFrames) {
            _updateState(LivenessState.lookingStraight);
          }
        } else {
          _straightCounter = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (_hasCompletedState() && _isLookingLeft(eulerY)) {
          _leftCounter++;
          if (_leftCounter >= requiredFrames) {
            _updateState(LivenessState.lookingLeft);
          }
        } else {
          _leftCounter = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (_hasCompletedState() && _isLookingRight(eulerY)) {
          _rightCounter++;
          if (_rightCounter >= requiredFrames) {
            _updateState(LivenessState.lookingRight);
          }
        } else {
          _rightCounter = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_hasCompletedState() && _isLookingStraight(eulerY)) {
          _straightAgainCounter++;
          if (_straightAgainCounter >= requiredFrames) {
            _updateState(LivenessState.lookingStraightAgain);
          }
        } else {
          _straightAgainCounter = 0;
        }
        break;

      case LivenessState.lookingStraightAgain:
        if (_hasCompletedState() && _isLookingStraight(eulerY)) {
          _updateState(LivenessState.complete);
        }
        break;

      default:
        break;
    }
  }

  bool _isLookingStraight(double eulerY) => eulerY >= -15 && eulerY <= 15;
  bool _isLookingLeft(double eulerY) => eulerY > 25;
  bool _isLookingRight(double eulerY) => eulerY < -25;
  bool _hasCompletedState() =>
      DateTime.now().difference(_stateStartTime).inMilliseconds >=
      stateDuration;

  void _updateState(LivenessState newState) {
    _currentState = newState;
    _stateStartTime = DateTime.now();
    _livenessStateController.add(newState);
  }

  void _handleError(String message) {
    final now = DateTime.now();
    if (now.difference(_lastErrorTime).inMilliseconds < 1000) {
      _consecutiveErrorCount++;
      if (_consecutiveErrorCount >= 3) {
        reset();
        return;
      }
    } else {
      _consecutiveErrorCount = 1;
    }

    _lastErrorTime = now;
    _updateState(LivenessState.error);
  }

  void _resetCounters() {
    _straightCounter = 0;
    _leftCounter = 0;
    _rightCounter = 0;
    _straightAgainCounter = 0;
  }

  void reset() {
    _currentState = LivenessState.initial;
    _stateStartTime = DateTime.now();
    _consecutiveErrorCount = 0;
    _lastErrorTime = DateTime.now();
    _resetCounters();
    _livenessStateController.add(LivenessState.initial);
  }

  void dispose() {
    _faceDetector.close();
    _livenessStateController.close();
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
