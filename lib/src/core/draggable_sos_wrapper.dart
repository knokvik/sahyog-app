import 'package:flutter/material.dart';

class DraggableSosWrapper extends StatefulWidget {
  final Widget child;

  const DraggableSosWrapper({super.key, required this.child});

  @override
  State<DraggableSosWrapper> createState() => _DraggableSosWrapperState();
}

class _DraggableSosWrapperState extends State<DraggableSosWrapper> {
  Offset _position = const Offset(0, 0);
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      final size = MediaQuery.of(context).size;
      // Initialize to bottom-right corner above standard BottomNavigationBar
      _position = Offset(size.width - 76, size.height - 160);
      _initialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final size = MediaQuery.of(context).size;
            // Add some bounds so it doesn't leave the screen entirely
            final newDx = (_position.dx + details.delta.dx).clamp(
              0.0,
              size.width - 60,
            );
            final newDy = (_position.dy + details.delta.dy).clamp(
              0.0,
              size.height - 60,
            );
            _position = Offset(newDx, newDy);
          });
        },
        // We use opaque behavior so the drag events are always caught by this wrapper
        behavior: HitTestBehavior.deferToChild,
        child: widget.child,
      ),
    );
  }
}
