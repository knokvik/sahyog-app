import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ai_validator_service.dart';

class SosConfirmationTimer extends StatefulWidget {
  const SosConfirmationTimer({
    super.key,
    required this.validationResult,
    required this.onCancel,
    required this.onConfirm,
    this.seconds = 10,
  });

  final DistressValidationResult validationResult;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final int seconds;

  @override
  State<SosConfirmationTimer> createState() => _SosConfirmationTimerState();
}

class _SosConfirmationTimerState extends State<SosConfirmationTimer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration: Duration(seconds: widget.seconds),
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && !_completed) {
              _completed = true;
              widget.onConfirm();
            }
          })
          ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confidencePct = (widget.validationResult.likelyHurtConfidence * 100)
        .toStringAsFixed(1);

    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0F1115).withValues(alpha: 0.94),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            children: [
              const SizedBox(height: 12),
              const Text(
                'Possible Distress Detected',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'AI confidence: $confidencePct% likely hurt',
                style: const TextStyle(
                  color: Color(0xFFFFB4A5),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 90,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final pulse =
                        1.0 + (0.08 * math.sin(_controller.value * 20));
                    return Transform.scale(
                      scale: pulse,
                      child: const Icon(
                        Icons.sos,
                        color: Color(0xFFFF3B30),
                        size: 52,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Center(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final leftRatio = 1 - _controller.value;
                      final secondsLeft = ((widget.seconds * leftRatio).ceil())
                          .clamp(0, widget.seconds);

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 240,
                            height: 240,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 220,
                                  height: 220,
                                  child: CircularProgressIndicator(
                                    value: leftRatio,
                                    strokeWidth: 14,
                                    backgroundColor: Colors.white12,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Color(0xFFFF3B30),
                                        ),
                                  ),
                                ),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '$secondsLeft',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 76,
                                        height: 1,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    const Text(
                                      'seconds to cancel',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Text(
                            'Snapshots and 5-second audio are being captured securely.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    if (_completed) return;
                    _completed = true;
                    _controller.stop();
                    widget.onCancel();
                  },
                  icon: const Icon(Icons.cancel, size: 28),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Cancel SOS',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFD70015),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  if (_completed) return;
                  _completed = true;
                  _controller.stop();
                  widget.onConfirm();
                },
                child: const Text(
                  'Send Immediately',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
