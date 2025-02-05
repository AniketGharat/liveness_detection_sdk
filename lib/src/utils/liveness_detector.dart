import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  bool _isFaceDetected = false;

  int _centeredFrames = 0;
  int _leftFrames = 0;
  int _rightFrames = 0;
  double _progress = 0.0;

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
      minFaceSize: 0.15, // Reduced to detect faces more easily
      performanceMode: FaceDetectorMode.accurate,
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
        if (_isFaceDetected) {
          _isFaceDetected = false;
          _resetProgress();
          onStateChanged(LivenessState.initial, 0.0);
        }
      } else {
        _isFaceDetected = true;
        await _updateFacePosition(faces.first);
      }
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
      rotation: InputImageRotation.rotation270deg, // Adjusted for front camera
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  void _resetProgress() {
    _centeredFrames = 0;
    _leftFrames = 0;
    _rightFrames = 0;
    _progress = 0.0;
    _currentState = LivenessState.initial;
  }

  Future<void> _updateFacePosition(Face face) async {
    final double? eulerY = face.headEulerAngleY;

    // Debug print for face angles
    print(
        'Face angles - Y: ${face.headEulerAngleY}, Z: ${face.headEulerAngleZ}');

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _centeredFrames++;
          if (_centeredFrames >= config.requiredFrames) {
            _updateState(LivenessState.lookingStraight);
          }
        } else {
          _centeredFrames = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (eulerY != null && eulerY < -config.turnThreshold) {
          _leftFrames++;
          if (_leftFrames >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
          }
        } else {
          _leftFrames = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (eulerY != null && eulerY > config.turnThreshold) {
          _rightFrames++;
          if (_rightFrames >= config.requiredFrames) {
            _updateState(LivenessState.lookingRight);
          }
        } else {
          _rightFrames = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _updateState(LivenessState.complete);
        }
        break;

      case LivenessState.complete:
        break;
    }
  }

  bool _isFaceCentered(Face face) {
    final double? eulerY = face.headEulerAngleY;
    final double? eulerZ = face.headEulerAngleZ;

    return (eulerY != null && eulerY.abs() < config.straightThreshold) &&
        (eulerZ != null && eulerZ.abs() < config.straightThreshold);
  }

  void _updateState(LivenessState newState) {
    _currentState = newState;

    _progress = switch (_currentState) {
      LivenessState.initial => 0.0,
      LivenessState.lookingStraight => 0.25,
      LivenessState.lookingLeft => 0.5,
      LivenessState.lookingRight => 0.75,
      LivenessState.complete => 1.0,
    };

    onStateChanged(_currentState, _progress);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}
