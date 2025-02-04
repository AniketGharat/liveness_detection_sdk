import 'dart:async';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/liveness_config.dart';
import '../models/liveness_result.dart';
import '../models/liveness_state.dart';

class LivenessDetector {
  final LivenessConfig config;
  final _stateController = StreamController<LivenessState>.broadcast();
  final _resultController = StreamController<LivenessResult>.broadcast();
  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.25,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  Stream<LivenessState> get livenessState => _stateController.stream;
  Stream<LivenessResult> get detectionResult => _resultController.stream;

  LivenessState _currentState = LivenessState.initial;
  int _straightCounter = 0;
  int _leftCounter = 0;
  int _rightCounter = 0;
  int _straightAgainCounter = 0;
  DateTime _stateStartTime = DateTime.now();
  bool _isProcessing = false;
  bool _isDisposed = false;

  LivenessDetector({this.config = const LivenessConfig()});

  Future<void> processImage(
      CameraImage image, InputImageRotation rotation) async {
    if (_isProcessing || _isDisposed) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image, rotation);
      if (!_isDisposed) {
        final faces = await _faceDetector.processImage(inputImage);
        if (!_isDisposed) {
          _handleFaceDetectionResult(faces);
        }
      }
    } catch (e) {
      if (!_isDisposed) {
        _emitError('Processing error: ${e.toString()}');
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage> _convertCameraImageToInputImage(
      CameraImage image, InputImageRotation rotation) async {
    final writeBuffer = WriteBuffer();
    for (final plane in image.planes) {
      writeBuffer.putUint8List(plane.bytes);
    }
    final bytes = writeBuffer.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  void _handleFaceDetectionResult(List<Face> faces) {
    if (_isDisposed) return;

    if (faces.isEmpty) {
      _emitError('No face detected');
      return;
    }

    if (faces.length > 1) {
      _emitError('Multiple faces detected');
      return;
    }

    final face = faces.first;
    _processFace(face);
  }

  void _processFace(Face face) {
    if (_isDisposed) return;

    final eulerY = face.headEulerAngleY ?? 0;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isLookingStraight(eulerY)) {
          _straightCounter++;
          if (_straightCounter >= config.requiredFrames) {
            _updateState(LivenessState.lookingStraight);
          }
        } else {
          _straightCounter = 0;
        }
        break;
      case LivenessState.lookingStraight:
        if (_hasCompletedState() && _isLookingLeft(eulerY)) {
          _leftCounter++;
          if (_leftCounter >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
          }
        } else {
          _leftCounter = 0;
        }
        break;
      case LivenessState.lookingLeft:
        if (_hasCompletedState() && _isLookingRight(eulerY)) {
          _rightCounter++;
          if (_rightCounter >= config.requiredFrames) {
            _updateState(LivenessState.lookingRight);
          }
        } else {
          _rightCounter = 0;
        }
        break;
      case LivenessState.lookingRight:
        if (_hasCompletedState() && _isLookingStraight(eulerY)) {
          _straightAgainCounter++;
          if (_straightAgainCounter >= config.requiredFrames) {
            _updateState(LivenessState.complete);
            _emitSuccess();
          }
        } else {
          _straightAgainCounter = 0;
        }
        break;
      default:
        break;
    }
  }

  void _emitSuccess() {
    if (!_isDisposed) {
      _resultController.add(LivenessResult(
        isSuccess: true,
        state: LivenessState.complete,
      ));
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
    if (!_isDisposed) {
      _currentState = newState;
      _stateStartTime = DateTime.now();
      _stateController.add(newState);
    }
  }

  void _emitError(String message) {
    if (!_isDisposed) {
      _updateState(LivenessState.error);
      _resultController.add(LivenessResult(
        isSuccess: false,
        errorMessage: message,
        state: LivenessState.error,
      ));
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _faceDetector.close();
    await _stateController.close();
    await _resultController.close();
  }
}
