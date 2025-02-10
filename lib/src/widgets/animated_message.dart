import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liveness_detection_sdk/liveness_sdk.dart';

class AnimatedLivenessMessage extends StatefulWidget {
  final String message;
  final LivenessState state;

  const AnimatedLivenessMessage({
    Key? key,
    required this.message,
    required this.state,
  }) : super(key: key);

  @override
  State<AnimatedLivenessMessage> createState() =>
      _AnimatedLivenessMessageState();
}

class _AnimatedLivenessMessageState extends State<AnimatedLivenessMessage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  String _displayedMessage = '';

  @override
  void initState() {
    super.initState();
    _displayedMessage = widget.message;
    _initializeAnimations();
  }

  void _initializeAnimations() {
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.2),
        weight: 40.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.2, end: 1.0),
        weight: 60.0,
      ),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 40.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.0),
        weight: 60.0,
      ),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _controller.forward();
  }

  @override
  void didUpdateWidget(AnimatedLivenessMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message != oldWidget.message) {
      setState(() {
        _displayedMessage = widget.message;
      });
      _controller.reset();
      _controller.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _opacityAnimation.value,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.state == LivenessState.complete
                      ? Colors.green.withOpacity(0.3)
                      : Colors.white.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Text(
                _displayedMessage,
                style: TextStyle(
                  color: widget.state == LivenessState.complete
                      ? Colors.green
                      : Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
