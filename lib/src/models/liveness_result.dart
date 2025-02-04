import 'liveness_state.dart';

class LivenessResult {
  final bool isSuccess;
  final LivenessState state;
  final String? errorMessage;
  final String? imagePath;

  LivenessResult({
    required this.isSuccess,
    required this.state,
    this.errorMessage,
    this.imagePath,
  });
}
