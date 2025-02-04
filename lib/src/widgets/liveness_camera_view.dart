import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../models/liveness_result.dart';
import '../utils/liveness_detector.dart';

class LivenessCameraView extends StatefulWidget {
  final Function(LivenessResult result) onResult;

  const LivenessCameraView({required this.onResult, Key? key})
      : super(key: key);

  @override
  _LivenessCameraViewState createState() => _LivenessCameraViewState();
}

class _LivenessCameraViewState extends State<LivenessCameraView> {
  late LivenessDetector _livenessDetector;
  CameraController? _cameraController;
  bool _isCameraReady = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _livenessDetector = LivenessDetector();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;
    _cameraController = CameraController(camera, ResolutionPreset.high);
    await _cameraController?.initialize();

    if (!mounted) return;
    setState(() {
      _isCameraReady = true;
    });

    _cameraController?.startImageStream((CameraImage image) {
      _livenessDetector.processImage(image, InputImageRotation.rotation0deg);
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _livenessDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _isCameraReady
            ? CameraPreview(_cameraController!)
            : CircularProgressIndicator(),
      ),
    );
  }
}
