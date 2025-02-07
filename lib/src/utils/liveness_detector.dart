import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double, String) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  int _requiredFramesCount = 0;

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

  Future<void> processImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _updateState(LivenessState.initial, "Position your face in the circle");
        return;
      }

      if (faces.length > 1) {
        _updateState(LivenessState.initial, "Multiple faces detected");
        return;
      }

      final face = faces.first;
      await _processDetectedFace(face);
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
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
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(
                LivenessState.lookingStraight, "Now turn your head left");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingStraight:
        if (headEulerY < -config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft, "Now turn your head right");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingLeft:
        if (headEulerY > config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingRight, "Now center your face");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.complete, "Perfect! Processing...");
          }
        } else {
          _resetProgress();
        }
        break;

      case LivenessState.complete:
        break;
    }
  }

  bool _isFaceCentered(Face face) {
    final eulerY = face.headEulerAngleY ?? 0.0;
    final eulerZ = face.headEulerAngleZ ?? 0.0;
    return eulerY.abs() < config.straightThreshold &&
        eulerZ.abs() < config.straightThreshold;
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
  }

  void _updateState(LivenessState newState, String message) {
    _currentState = newState;
    final progress = switch (newState) {
      LivenessState.initial => 0.0,
      LivenessState.lookingStraight => 0.25,
      LivenessState.lookingLeft => 0.5,
      LivenessState.lookingRight => 0.75,
      LivenessState.complete => 1.0,
    };
    _requiredFramesCount = 0;
    onStateChanged(newState, progress, message);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}
