// liveness_detector.dart
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
  Timer? _faceDetectionTimer;
  double _progress = 0.0;
  int _requiredFramesCount = 0;
  Rect? _faceFrame;

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
        _handleNoFace();
      } else {
        final validFaces = faces.where((face) => _isFaceInFrame(face)).toList();
        if (validFaces.isNotEmpty) {
          final largestFace = validFaces.reduce((a, b) =>
              a.boundingBox.width * a.boundingBox.height >
                      b.boundingBox.width * b.boundingBox.height
                  ? a
                  : b);
          await _updateFacePosition(largestFace);
        } else {
          _handleNoFace();
        }
      }
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _handleNoFace() {
    onStateChanged(LivenessState.initial, 0.0);
    _faceDetectionTimer?.cancel();
    _resetProgress();
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
    _currentState = LivenessState.initial;
    _progress = 0.0;
  }

  Future<void> _updateFacePosition(Face face) async {
    final double? eulerY = face.headEulerAngleY;
    final double? adjustedEulerY = eulerY != null ? -eulerY : null;

    if (!_isFaceCentered(face)) {
      _requiredFramesCount = 0;
      return;
    }

    switch (_currentState) {
      case LivenessState.initial:
        _requiredFramesCount++;
        if (_requiredFramesCount >= 5) {
          _updateState(LivenessState.lookingStraight);
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
        _requiredFramesCount++;
        if (_requiredFramesCount >= 5) {
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

  bool _isFaceInFrame(Face face) {
    final faceRect = face.boundingBox;
    return faceRect.center.dx >= _faceFrame!.left &&
        faceRect.center.dx <= _faceFrame!.right &&
        faceRect.center.dy >= _faceFrame!.top &&
        faceRect.center.dy <= _faceFrame!.bottom;
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

  void setFaceFrame(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * (config.circleSize / 2);
    _faceFrame = Rect.fromCircle(center: center, radius: radius);
  }

  Future<void> dispose() async {
    _faceDetectionTimer?.cancel();
    await _faceDetector.close();
  }
}
