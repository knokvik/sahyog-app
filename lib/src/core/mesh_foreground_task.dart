import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'mesh_relay_service.dart';

@pragma('vm:entry-point')
void meshStartCallback() {
  FlutterForegroundTask.setTaskHandler(MeshTaskHandler());
}

class MeshTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (Platform.isAndroid) {
      await MeshRelayService.instance.start();
    }
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // MeshRelayService has its own timer; no-op here.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    if (Platform.isAndroid) {
      await MeshRelayService.instance.stop();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

