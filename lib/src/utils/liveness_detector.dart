import 'dart:async';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/liveness_config.dart';
import '../models/liveness_result.dart';
import '../models/liveness_state.dart';

class LivenessDetector {
  final LivenessConfig config;
  final _stateController = StreamController<LivenessState>.broadcast();
  final _resultController = StreamController<LivenessResult>.broadcast();

  Stream<LivenessState> get livenessState => _stateController.stream;
  Stream<LivenessResult> get detectionResult => _resultController.stream;

  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.25,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  LivenessState _currentState = LivenessState.initial;
  int _straightCounter = 0;
  int _leftCounter = 0;
  int _rightCounter = 0;
  int _straightAgainCounter = 0;
  DateTime _stateStartTime = DateTime.now();
  bool _isProcessing = false;

  LivenessDetector({this.config = const LivenessConfig()});

  Future<void> processImage(
      CameraImage image, InputImageRotation rotation) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImageToInputImage(image, rotation);
      final faces = await _faceDetector.processImage(inputImage);
      _handleFaceDetectionResult(faces);
    } finally {
      _isProcessing = false;
    }
  }

  void _handleFaceDetectionResult(List<Face> faces) {
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
    final eulerY = face.headEulerAngleY ?? 0;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isLookingStraight(eulerY)) {
          _straightCounter++;
          if (_straightCounter >= config.requiredFrames) {
            _updateState(LivenessState.lookingStraight);
          }
        }
        break;
      case LivenessState.lookingStraight:
        if (_hasCompletedState() && _isLookingLeft(eulerY)) {
          _leftCounter++;
          if (_leftCounter >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
          }
        }
        break;
      // Add other state processing logic...
      default:
        break;
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
  }

  void _emitError(String message) {
    _updateState(LivenessState.error);
    _resultController.add(LivenessResult(
      isSuccess: false,
      errorMessage: message,
      state: LivenessState.error,
    ));
  }

  Future<void> dispose() async {
    await _faceDetector.close();
    await _stateController.close();
    await _resultController.close();
  }

  // Helper method to convert CameraImage to InputImage
  InputImage _convertCameraImageToInputImage(
      CameraImage image, InputImageRotation rotation) {
    // Implementation details...
    throw UnimplementedError();
  }
}
