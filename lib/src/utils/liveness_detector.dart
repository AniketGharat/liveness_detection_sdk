import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';

import '../models/liveness_config.dart';
import '../models/liveness_result.dart';
import '../models/liveness_state.dart';

class LivenessDetector {
  final LivenessConfig config;
  final Function(List<Face> faces)
      onFaceDetected; // Callback function for face detection
  FaceDetector? _faceDetector;
  bool _isProcessing = false;
  LivenessState _currentState = LivenessState.initial;

  LivenessState get currentState => _currentState;

  LivenessDetector(
      {this.config = const LivenessConfig(), required this.onFaceDetected}) {
    _initializeFaceDetector();
  }

  void _initializeFaceDetector() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        minFaceSize: 0.25,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
  }

  Future<void> processImage(
      CameraImage image, InputImageRotation rotation) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = await _convertCameraImageToInputImage(image, rotation);
      final faces = await _faceDetector?.processImage(inputImage);

      if (faces != null) {
        onFaceDetected(faces); // Send the faces to the callback function
      }
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage> _convertCameraImageToInputImage(
      CameraImage image, InputImageRotation rotation) async {
    final bytes = await _concatenatePlanes(image.planes);
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.bgra8888,
      bytesPerRow: image.planes[0].bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  Future<Uint8List> _concatenatePlanes(List<Plane> planes) async {
    final WriteBuffer allBytes = WriteBuffer();
    for (final plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  Future<String?> _captureImage(CameraImage image) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final String fileName =
          'liveness_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String filePath = '${directory.path}/$fileName';

      final bytes = await _concatenatePlanes(image.planes);
      final File imageFile = File(filePath);
      await imageFile.writeAsBytes(bytes);
      return filePath;
    } catch (e) {
      print('Error capturing image: $e');
      return null;
    }
  }

  void updateLivenessState(LivenessState state) {
    _currentState = state;
  }

  void dispose() async {
    await _faceDetector?.close();
  }
}
