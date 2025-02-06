import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../liveness_sdk.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(LivenessState, double) onStateChanged;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;
  bool _isFaceDetected = false;
  double _progress = 0.0;
  int _requiredFramesCount = 0;
  int _noFaceFrameCount = 0;
  int _multipleFacesFrameCount = 0;
  Rect? _lastFaceRect;
  Size? _lastImageSize;

  // Constants for face detection
  static const int _frameThreshold = 5;
  static const double _faceAreaThreshold = 0.15;
  static const double _maxFaceAreaThreshold = 0.85;

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
      enableTracking: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.accurate,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<InputImage> _convertCameraImageToInputImage(CameraImage image) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }

    final bytes = allBytes.done().buffer.asUint8List();

    _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());

    final metadata = InputImageMetadata(
      size: _lastImageSize!,
      rotation: InputImageRotation.rotation90deg,
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
      } else if (faces.length > 1) {
        _handleMultipleFaces();
      } else {
        final face = faces.first;
        if (_isFaceWithinBounds(face)) {
          await _processSingleFace(face);
        } else {
          _handleFaceOutOfBounds();
        }
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
      _handleError();
    } finally {
      _isProcessing = false;
    }
  }

  bool _isFaceWithinBounds(Face face) {
    if (_lastImageSize == null) return false;

    final Rect faceRect = face.boundingBox;
    final double imageArea = _lastImageSize!.width * _lastImageSize!.height;
    final double faceArea = faceRect.width * faceRect.height;
    final double faceAreaRatio = faceArea / imageArea;

    // Check if face is too small or too large
    if (faceAreaRatio < _faceAreaThreshold ||
        faceAreaRatio > _maxFaceAreaThreshold) {
      return false;
    }

    // Define the valid frame area
    final frameRect = Rect.fromLTRB(
      _lastImageSize!.width * 0.1,
      _lastImageSize!.height * 0.1,
      _lastImageSize!.width * 0.9,
      _lastImageSize!.height * 0.9,
    );

    _lastFaceRect = faceRect;
    return frameRect.contains(faceRect.center);
  }

  Future<void> _processSingleFace(Face face) async {
    _noFaceFrameCount = 0;
    _multipleFacesFrameCount = 0;

    if (!_isFaceDetected) {
      _isFaceDetected = true;
      config.onFaceDetected?.call(true);
    }

    await _updateFacePosition(face);
  }

  void _handleNoFace() {
    _noFaceFrameCount++;
    if (_noFaceFrameCount >= _frameThreshold) {
      if (_isFaceDetected) {
        _isFaceDetected = false;
        _resetProgress();
        config.onFaceDetected?.call(false);
        onStateChanged(LivenessState.initial, _progress);
      }
    }
  }

  void _handleMultipleFaces() {
    _multipleFacesFrameCount++;
    if (_multipleFacesFrameCount >= _frameThreshold) {
      _resetProgress();
      config.onMultipleFaces?.call(true);
      _currentState = LivenessState.initial;
      onStateChanged(_currentState, _progress);
    }
  }

  void _handleFaceOutOfBounds() {
    if (_currentState != LivenessState.initial) {
      _resetProgress();
      onStateChanged(LivenessState.initial, _progress);
    }
  }

  void _handleError() {
    _resetProgress();
    onStateChanged(LivenessState.initial, _progress);
  }

  void _resetProgress() {
    _requiredFramesCount = 0;
    _currentState = LivenessState.initial;
    _progress = 0.0;
    _lastFaceRect = null;
    _noFaceFrameCount = 0;
    _multipleFacesFrameCount = 0;
  }

  Future<void> _updateFacePosition(Face face) async {
    final double? eulerY = face.headEulerAngleY;
    final double? adjustedEulerY = eulerY != null ? -eulerY : null;

    switch (_currentState) {
      case LivenessState.initial:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingStraight);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingStraight:
        if (adjustedEulerY != null && adjustedEulerY < -config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingLeft);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingLeft:
        if (adjustedEulerY != null && adjustedEulerY > config.turnThreshold) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
            _updateState(LivenessState.lookingRight);
          }
        } else {
          _requiredFramesCount = 0;
        }
        break;

      case LivenessState.lookingRight:
        if (_isFaceCentered(face)) {
          _requiredFramesCount++;
          if (_requiredFramesCount >= config.requiredFrames) {
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

    if (eulerY == null || eulerZ == null) return false;

    final bool isYAxisCentered = eulerY.abs() < config.straightThreshold;
    final bool isZAxisCentered = eulerZ.abs() < config.straightThreshold;

    // Add additional checks for face landmarks if needed
    final bool hasRequiredLandmarks = face.landmarks.isNotEmpty;

    return isYAxisCentered && isZAxisCentered && hasRequiredLandmarks;
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
    await _faceDetector.close();
  }
}
