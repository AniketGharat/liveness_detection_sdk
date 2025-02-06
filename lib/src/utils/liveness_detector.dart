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
  Timer? _faceDetectionTimer;
  double _progress = 0.0;

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

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final width = image.width;
    final height = image.height;
    final planes = image.planes;

    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }

    final bytes = allBytes.done().buffer.asUint8List();
    final metadata = InputImageMetadata(
      size: Size(width.toDouble(), height.toDouble()),
      rotation: InputImageRotation.rotation270deg,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
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
          onStateChanged(LivenessState.initial, _progress);
          _faceDetectionTimer?.cancel();
        }
      } else {
        if (!_isFaceDetected) {
          _isFaceDetected = true;
          _currentState = LivenessState.initial;
          _startFaceDetectionTimer();
        }
        for (var face in faces) {
          await _updateFacePosition(face);
        }
      }
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _startFaceDetectionTimer() {
    _faceDetectionTimer?.cancel();
    _faceDetectionTimer = Timer(const Duration(seconds: 1), () {
      if (_isFaceDetected && _currentState == LivenessState.initial) {
        _updateState(LivenessState.lookingStraight);
      }
    });
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
    _currentState = LivenessState.initial;
    _progress = 0.0;
  }

  Future<void> _updateFacePosition(Face face) async {
    final double? eulerY = face.headEulerAngleY;
    final double? adjustedEulerY = eulerY != null ? -eulerY : null;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= 5) {
            _updateState(LivenessState.lookingStraight);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (adjustedEulerY != null && adjustedEulerY < -config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= 5) {
            _updateState(LivenessState.lookingLeft);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (adjustedEulerY != null && adjustedEulerY > config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= 5) {
            _updateState(LivenessState.lookingRight);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= 5) {
            _updateState(LivenessState.complete);
          }
        } else {
          _requiredFramesCount = 0;
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
    _requiredFramesCount = 0;
    onStateChanged(_currentState, _progress);
  }

  Future<void> dispose() async {
    _faceDetectionTimer?.cancel();
    await _faceDetector.close();
  }
}
