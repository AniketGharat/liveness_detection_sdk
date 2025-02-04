class LivenessResult {
  final bool isSuccess;
  final String? imagePath;
  final String? errorMessage;

  LivenessResult({
    required this.isSuccess,
    this.imagePath,
    this.errorMessage,
  });
}
