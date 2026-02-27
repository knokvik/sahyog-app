import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:picovoice_flutter/picovoice_manager.dart';
import 'package:rhino_flutter/rhino.dart';
import 'package:vibration/vibration.dart';

import 'api_client.dart';
import 'database_helper.dart';
import 'location_service.dart';
import 'sos_state_machine.dart';
import 'sos_sync_engine.dart';

/// Lightweight, opt‑in voice‑triggered SOS service.
///
/// This wraps Picovoice wake‑word + intent detection and, on a confirmed
/// "distress" intent, creates a normal SOS incident using the same
/// SQLite + sync pipeline as the manual Emergency SOS button.
///
/// Design notes:
/// - No "always on" by default — caller must explicitly initialize with
///   a valid access key and model paths.
/// - If Picovoice models or access key are missing/invalid, the service
///   fails gracefully and does nothing (no crashes).
/// - Uses Connectivity + SosSyncEngine for online/offline behaviour.
class VoiceSosService {
  VoiceSosService._();
  static final VoiceSosService instance = VoiceSosService._();

  PicovoiceManager? _manager;
  final _locationService = LocationService();
  final _connectivity = Connectivity();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _isHandlingIntent = false;

  String? _reporterId;
  ApiClient? _api;

  Future<void> initialize({
    required String reporterId,
    required ApiClient api,
    required String accessKey,
    required String keywordPath,
    required String contextPath,
  }) async {
    if (_initialized) return;

    if (accessKey.isEmpty) {
      SosLog.warn('VOICE_SOS', 'No Picovoice access key provided — disabled');
      return;
    }

    _reporterId = reporterId;
    _api = api;

    // Request mic permission up front
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      SosLog.warn('VOICE_SOS', 'Microphone permission denied — disabled');
      return;
    }

    // Basic local notification channel (Android); safe no‑op on iOS if unconfigured.
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(initSettings);

    try {
      _manager = await PicovoiceManager.create(
        accessKey,
        keywordPath,
        _onWakeWord,
        contextPath,
        _onInference,
      );
      await _manager!.start();
      _initialized = true;
      SosLog.event('VOICE_SOS', 'INIT_SUCCESS', 'Voice SOS listener started');
    } catch (e) {
      SosLog.warn('VOICE_SOS_INIT', 'Picovoice error: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _manager?.stop();
      await _manager?.delete();
    } catch (_) {}
    _manager = null;
    _initialized = false;
  }

  void _onWakeWord() {
    // Subtle haptic cue so the user knows the app is listening.
    Vibration.hasVibrator().then((hasVibrator) {
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 80, amplitude: 80);
      }
    });
    SosLog.event('VOICE_SOS', 'WAKE_WORD_DETECTED');
  }

  Future<void> _onInference(RhinoInference inference) async {
    if (inference.isUnderstood != true) return;
    if (_isHandlingIntent) return;

    final intent = inference.intent;
    if (intent != 'sos_distress') {
      SosLog.event('VOICE_SOS', 'IGNORED_INTENT', intent);
      return;
    }

    _isHandlingIntent = true;
    try {
      final reporterId = _reporterId;
      final api = _api;
      if (reporterId == null || api == null) {
        SosLog.warn('VOICE_SOS', 'Missing reporterId/api — cannot trigger SOS');
        return;
      }

      await _handleVoiceTriggeredSos(reporterId, api);
    } catch (e) {
      SosLog.warn('VOICE_SOS', 'INTENT_HANDLER_ERROR: $e');
    } finally {
      _isHandlingIntent = false;
    }
  }

  Future<void> _handleVoiceTriggeredSos(
    String reporterId,
    ApiClient api,
  ) async {
    final db = DatabaseHelper.instance;

    // Prevent double‑trigger if a SOS is already active
    final existing = await db.getActiveIncident(reporterId);
    if (existing != null) {
      SosLog.event(existing.uuid, 'VOICE_DOUBLE_TRIGGER_BLOCKED');
      await _showNotification(
        title: 'SOS Already Active',
        body: 'Your SOS is already broadcasting to responders.',
      );
      return;
    }

    // Location lookup (shorter timeout than UI flow to keep it snappy)
    Position? pos;
    try {
      pos = await _locationService.getCurrentPosition().timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {}

    final incident = SosIncident(
      reporterId: reporterId,
      lat: pos?.latitude,
      lng: pos?.longitude,
      type: 'Emergency',
      status: SosStatus.activating,
    );

    SosLog.event(
      incident.uuid,
      'VOICE_ACTIVATE',
      'lat=${pos?.latitude}, lng=${pos?.longitude}',
    );

    await db.insertSosIncident(incident);
    await db.atomicUpdateIncident(
      incident.uuid,
      status: SosStatus.activeOffline,
    );

    // Decide online / offline behaviour
    final results = await _connectivity.checkConnectivity();
    final hasNetwork = results.any((r) => r != ConnectivityResult.none);

    if (hasNetwork) {
      SosLog.event(incident.uuid, 'VOICE_IMMEDIATE_SYNC');
      await SosSyncEngine.instance.syncAll();
      await _showNotification(
        title: 'Voice SOS Sent',
        body: 'Your distress SOS has been sent to responders.',
      );
    } else {
      SosLog.event(incident.uuid, 'VOICE_OFFLINE_SOS');
      await _showNotification(
        title: 'Voice SOS Saved (Offline)',
        body: 'No signal. SOS will sync automatically when you are online.',
      );
    }
  }

  Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'voice_sos_channel',
        'Voice SOS',
        channelDescription: 'Alerts for voice‑triggered SOS events',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      );
      const details = NotificationDetails(android: androidDetails);

      await _notifications.show(1001, title, body, details);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('VOICE_SOS: Notification failed: $e');
      }
    }
  }
}
