import 'package:flutter/material.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';
import 'package:lottie/lottie.dart';

class StateAnimation extends StatelessWidget {
  final String animationPath;
  final AnimationController controller;
  final LivenessState state;
  final double progress;

  const StateAnimation({
    Key? key,
    required this.animationPath,
    required this.controller,
    required this.state,
    required this.progress,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.15,
      left: 0,
      right: 0,
      child: Column(
        children: [
          _buildAnimationContent(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildAnimationContent() {
    switch (state) {
      case LivenessState.lookingLeft:
      case LivenessState.lookingRight:
        return _buildTurnAnimation();
      case LivenessState.multipleFaces:
        return _buildErrorAnimation();
      case LivenessState.complete:
        return _buildSuccessAnimation();
      default:
        return _buildDefaultAnimation();
    }
  }

  Widget _buildTurnAnimation() {
    final isLeft = state == LivenessState.lookingLeft;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLeft)
              const Icon(Icons.arrow_back_ios, color: Colors.white, size: 32),
            Container(
              width: 120,
              height: 120,
              child: Lottie.asset(
                animationPath,
                controller: controller,
                package: 'liveness_detection_sdk',
              ),
            ),
            if (!isLeft)
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white, size: 32),
          ],
        ),
        const SizedBox(height: 16),
        _buildTurnProgressIndicator(),
      ],
    );
  }

  Widget _buildTurnProgressIndicator() {
    final isLeft = state == LivenessState.lookingLeft;
    return Container(
      width: 200,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        children: [
          FractionallySizedBox(
            widthFactor: progress,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLeft) const Icon(Icons.arrow_back, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  isLeft ? 'Turn Left' : 'Turn Right',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                if (!isLeft)
                  const Icon(Icons.arrow_forward, color: Colors.white),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorAnimation() {
    return Column(
      children: [
        Container(
          width: 120,
          height: 120,
          child: Lottie.asset(
            animationPath,
            controller: controller,
            package: 'liveness_detection_sdk',
          ),
        ),
        const Text(
          'Only one face should be visible',
          style: TextStyle(
            color: Colors.red,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessAnimation() {
    return Column(
      children: [
        Container(
          width: 120,
          height: 120,
          child: Lottie.asset(
            animationPath,
            controller: controller,
            package: 'liveness_detection_sdk',
          ),
        ),
        const Text(
          'Verification Complete!',
          style: TextStyle(
            color: Colors.green,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildDefaultAnimation() {
    return Container(
      width: 120,
      height: 120,
      child: Lottie.asset(
        animationPath,
        controller: controller,
        package: 'liveness_detection_sdk',
      ),
    );
  }
}
