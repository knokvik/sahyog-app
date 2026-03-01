import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/ai_validator_service.dart';
import '../../core/database_helper.dart';
import '../../core/location_service.dart';
import '../../core/models.dart';
import '../../core/sos_state_machine.dart';
import '../../core/sos_sync_engine.dart';
import '../../core/voice_sos_service.dart';
import '../../theme/app_colors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../core/socket_service.dart';
import 'sos_alerts_panel.dart';
import 'sos_confirmation_timer.dart';

class EmergencySosBox extends StatefulWidget {
  const EmergencySosBox({
    super.key,
    required this.user,
    required this.api,
    this.onSosTap,
    this.onSosLocationTap,
  });

  final AppUser user;
  final ApiClient api;
  final VoidCallback? onSosTap;
  final Function(LatLng)? onSosLocationTap;

  @override
  State<EmergencySosBox> createState() => _EmergencySosBoxState();
}

class _EmergencySosBoxState extends State<EmergencySosBox>
    with AutomaticKeepAliveClientMixin {
  final _locationService = LocationService();
  final _aiValidator = AiValidatorService.instance;

  int _sosHoldTicks = 0;
  Timer? _sosHoldTimer;
  bool _sosFired = false;
  bool _validationInProgress = false;
  String? _activeSosId;
  String? _activeLocalUuid;

  @override
  void initState() {
    super.initState();
    _checkActiveSOS();
  }

  Future<void> _checkActiveSOS() async {
    final db = DatabaseHelper.instance;
    final active = await db.getActiveIncident(widget.user.id);
    if (active != null) {
      if (mounted) {
        setState(() {
          _activeLocalUuid = active.uuid;
          _activeSosId = active.backendId;
          _sosFired = true;
        });
      }
    }
  }

  VoiceSignalSample _readRecentVoiceSignal() {
    final hasSignal = VoiceSosService.instance.hasRecentDistressSignal();
    final rawScore = VoiceSosService.instance.recentDistressScore();
    return VoiceSignalSample(
      keywordDetected: hasSignal,
      keyword: VoiceSosService.instance.recentDistressKeyword(),
      screamScore: rawScore.clamp(0.0, 1.0),
      distressScore: hasSignal
          ? rawScore.clamp(0.72, 1.0)
          : rawScore.clamp(0.0, 1.0),
      detectedAt: hasSignal
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(0),
      source: hasSignal ? 'picovoice' : 'none',
    );
  }

  Future<String?> _loadFamilyContactsJson() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = prefs.getString('family_contacts');
      if (payload != null && payload.isNotEmpty) return payload;
    } catch (_) {}
    return null;
  }

  Future<bool> _confirmLowConfidenceSend(
    DistressValidationResult result,
  ) async {
    final confidence = (result.likelyHurtConfidence * 100).toStringAsFixed(1);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Low Distress Confidence'),
              content: Text('AI confidence is $confidence%. Send SOS anyway?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.criticalRed,
                  ),
                  child: const Text('Send SOS'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> _startValidatedSosFlow() async {
    if (_validationInProgress || _sosFired) return;

    if (mounted) {
      setState(() {
        _validationInProgress = true;
        _sosHoldTicks = 0;
      });
    }

    final db = DatabaseHelper.instance;
    String? quickFrontPhotoPath;
    try {
      final familyContactsJson = await _loadFamilyContactsJson();
      final voiceSignal = _readRecentVoiceSignal();
      final motionFuture = _aiValidator.collectMotionSample();
      final quickFrontFuture = _aiValidator.captureSnapshot(
        lens: CameraLensDirection.front,
        prefix: 'quick',
      );

      final motionSignal = await motionFuture;
      quickFrontPhotoPath = await quickFrontFuture;

      final validationResult = await _aiValidator.runQuickValidation(
        frontPhotoPath: quickFrontPhotoPath,
        motion: motionSignal,
        voice: voiceSignal,
      );

      if (!mounted) return;

      SosEvidenceBundle evidenceBundle;
      if (validationResult.isLikelyHurt) {
        final captureFuture = _aiValidator.captureCountdownEvidence();
        final shouldProceed =
            await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) {
                return SosConfirmationTimer(
                  validationResult: validationResult,
                  onCancel: () => Navigator.of(dialogContext).pop(false),
                  onConfirm: () => Navigator.of(dialogContext).pop(true),
                );
              },
            ) ??
            false;

        final captured = await captureFuture;
        evidenceBundle = SosEvidenceBundle(
          frontPhotoPath: captured.frontPhotoPath ?? quickFrontPhotoPath,
          backPhotoPath: captured.backPhotoPath,
          audioPath: captured.audioPath,
          capturedAt: captured.capturedAt,
        );

        if (!shouldProceed) {
          await _aiValidator.discardEvidence(evidenceBundle);
          if (mounted) {
            setState(() {
              _sosFired = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('SOS cancelled before dispatch.'),
                backgroundColor: AppColors.primaryGreen,
              ),
            );
          }
          return;
        }
      } else {
        final shouldProceed = await _confirmLowConfidenceSend(validationResult);
        if (!shouldProceed) {
          await _aiValidator.discardEvidence(
            SosEvidenceBundle(
              frontPhotoPath: quickFrontPhotoPath,
              backPhotoPath: null,
              audioPath: null,
              capturedAt: DateTime.now(),
            ),
          );
          return;
        }

        evidenceBundle = SosEvidenceBundle(
          frontPhotoPath: quickFrontPhotoPath,
          backPhotoPath: null,
          audioPath: null,
          capturedAt: DateTime.now(),
        );
      }

      final artifactId = await db.insertValidationArtifact(
        reporterId: widget.user.id,
        incidentUuid: null,
        frontPhotoPath: evidenceBundle.frontPhotoPath,
        backPhotoPath: evidenceBundle.backPhotoPath,
        audioPath: evidenceBundle.audioPath,
        quickScore: validationResult.imageScore,
        motionScore: validationResult.motionScore,
        voiceScore: validationResult.voiceScore,
        confidence: validationResult.likelyHurtConfidence,
        familyContacts: familyContactsJson,
        modelVersion: validationResult.modelVersion,
      );

      final localUuid = await _triggerSOS(
        validationResult: validationResult,
        validationArtifactId: artifactId,
        familyContactsJson: familyContactsJson,
      );

      if (localUuid != null) {
        try {
          await _aiValidator.sendValidationToOrchestrator(
            api: widget.api,
            result: validationResult,
            motion: motionSignal,
            voice: voiceSignal,
            evidence: evidenceBundle,
            reporterId: widget.user.id,
            familyContactsJson: familyContactsJson,
            localIncidentUuid: localUuid,
          );
          await db.markValidationArtifactSynced(artifactId);
        } catch (e) {
          SosLog.warn(
            'ORCHESTRATOR_VALIDATE',
            'Validation package queued locally: $e',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Validation failed. Please retry. ($e)'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _validationInProgress = false;
          _sosHoldTicks = 0;
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────
  // SOS Activation — State Machine Driven
  // ─────────────────────────────────────────────────────────

  Future<String?> _triggerSOS({
    DistressValidationResult? validationResult,
    int? validationArtifactId,
    String? familyContactsJson,
  }) async {
    final db = DatabaseHelper.instance;

    // Prevent double-trigger: check if already active
    final existing = await db.getActiveIncident(widget.user.id);
    if (existing != null) {
      SosLog.event(existing.uuid, 'DOUBLE_TRIGGER_BLOCKED');
      if (mounted) {
        setState(() {
          _activeLocalUuid = existing.uuid;
          _activeSosId = existing.backendId;
          _sosFired = true;
        });
      }
      return existing.uuid;
    }

    // 1. Fetch location (12s timeout)
    Position? pos;
    try {
      pos = await _locationService.getCurrentPosition().timeout(
        const Duration(seconds: 12),
      );
    } catch (_) {}

    final validationSummary = validationResult == null
        ? null
        : jsonEncode({
            'quick_validation': validationResult.toJson(),
            'artifact_id': validationArtifactId,
          });

    // 2. Create SOS incident
    final incident = SosIncident(
      reporterId: widget.user.id,
      lat: pos?.latitude,
      lng: pos?.longitude,
      type: 'Emergency',
      description: validationSummary,
      familyContacts: familyContactsJson,
      status: SosStatus.activating,
    );

    SosLog.event(
      incident.uuid,
      'ACTIVATE',
      'lat=${pos?.latitude}, lng=${pos?.longitude}',
    );

    // 3. Save to SQLite -> transition offline
    await db.insertSosIncident(incident);
    await db.atomicUpdateIncident(
      incident.uuid,
      status: SosStatus.activeOffline,
    );
    if (validationArtifactId != null) {
      await db.linkValidationArtifactToIncident(
        validationArtifactId,
        incident.uuid,
      );
    }

    if (mounted) {
      setState(() {
        _activeLocalUuid = incident.uuid;
        _sosFired = true;
      });
    }

    // 4. Force a network sync
    SosLog.event(incident.uuid, 'IMMEDIATE_SYNC_ATTEMPT');
    await SosSyncEngine.instance.syncAll();

    final updated = await db.getIncidentByUuid(incident.uuid);
    if (updated != null && updated.status == SosStatus.activeOnline) {
      if (mounted) {
        setState(() {
          _activeSosId = updated.backendId;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS Activated! Broadcasting to all responders...'),
            backgroundColor: AppColors.criticalRed,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SOS saved. Sync pending — will retry automatically.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ),
      );
    }
    return incident.uuid;
  }

  // ─────────────────────────────────────────────────────────
  // SOS Cancellation
  // ─────────────────────────────────────────────────────────

  Future<void> _cancelSOS() async {
    final db = DatabaseHelper.instance;
    final uuidToCancel = _activeLocalUuid;
    final backendIdToCancel = _activeSosId;

    SosLog.event(
      uuidToCancel ?? 'unknown',
      'CANCEL_INITIATED',
      'backendId=$backendIdToCancel',
    );

    if (mounted) {
      setState(() {
        _activeSosId = null;
        _activeLocalUuid = null;
        _sosFired = false;
        _sosHoldTicks = 0;
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_sos_id');

    if (uuidToCancel != null) {
      await db.atomicUpdateIncident(uuidToCancel, status: SosStatus.cancelled);
      SosLog.event(uuidToCancel, 'CANCEL_SQLITE', 'status=cancelled');
    }

    if (backendIdToCancel != null) {
      try {
        await widget.api.put('/api/v1/sos/$backendIdToCancel/cancel');
        SosLog.event(
          uuidToCancel ?? 'unknown',
          'CANCEL_SERVER',
          'backendId=$backendIdToCancel',
        );
        if (uuidToCancel != null) {
          await db.markCancellationSynced(uuidToCancel);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 12),
                  Text('SOS Cancelled. You are marked as safe.'),
                ],
              ),
              backgroundColor: AppColors.primaryGreen,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        SosLog.event(
          uuidToCancel ?? 'unknown',
          'CANCEL_SERVER_FAIL',
          'Will retry on reconnect. error=$e',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'SOS cancelled locally. Server will be notified when online.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      return;
    }

    SosLog.event(
      uuidToCancel ?? 'unknown',
      'CANCEL_OFFLINE',
      'No backend ID — local record cancelled. Will not sync.',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 12),
              Text('Offline SOS cancelled. No data sent.'),
            ],
          ),
          backgroundColor: AppColors.primaryGreen,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _cancelHold() {
    _sosHoldTimer?.cancel();
    if (mounted) {
      setState(() {
        _sosHoldTicks = 0;
      });
    }
  }

  @override
  void dispose() {
    _sosHoldTimer?.cancel();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildLeftSosButton() {
    return ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
      valueListenable: SocketService.instance.liveSosAlerts,
      builder: (context, alerts, _) {
        final count = alerts.length;
        return InkWell(
          onTap: () async {
            if (count > 0) {
              final active = await DatabaseHelper.instance.getActiveIncident(
                widget.user.id,
              );
              if (!context.mounted || !mounted) {
                return;
              }
              if (mounted) {
                SosAlertsPanel.show(
                  context: context,
                  alerts: alerts,
                  activeLocalUuid: active?.uuid,
                  onCancelSos: null,
                  onGoToSosPanels: () => widget.onSosTap?.call(),
                  onSosLocationTap: widget.onSosLocationTap != null
                      ? (lat, lng) => widget.onSosLocationTap!(LatLng(lat, lng))
                      : null,
                );
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No active SOS alerts')),
              );
            }
          },
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            bottomLeft: Radius.circular(16),
          ),
          child: Container(
            width: 64,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border(
                right: BorderSide(color: Colors.grey.shade300, width: 1),
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.sos, size: 24, color: AppColors.criticalRed),
                if (count > 0)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: AppColors.criticalRed,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRightMapButton() {
    return InkWell(
      onTap: () => widget.onSosTap?.call(),
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: Border(
            left: BorderSide(color: Colors.grey.shade300, width: 1),
          ),
        ),
        child: const Icon(
          Icons.pin_drop,
          color: AppColors.criticalRed,
          size: 24,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final double progress = (_sosHoldTicks / 50.0).clamp(0.0, 1.0);

    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: (_activeSosId != null || _sosFired)
                ? AppColors.criticalRed
                : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: (_activeSosId != null || _sosFired)
                  ? Colors.transparent
                  : AppColors.criticalRed,
              width: 2,
            ),
            boxShadow: [
              if (_activeSosId != null || _sosFired)
                BoxShadow(
                  color: AppColors.criticalRed.withValues(alpha: 0.4),
                  blurRadius: 15,
                  spreadRadius: 2,
                )
              else if (_sosHoldTicks > 0)
                BoxShadow(
                  color: AppColors.criticalRed.withValues(alpha: 0.3),
                  blurRadius: 10,
                  spreadRadius: progress * 5,
                ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left Partition
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width:
                      (_sosHoldTicks == 0 && _activeSosId == null && !_sosFired)
                      ? 64
                      : 0,
                  child:
                      (_sosHoldTicks == 0 && _activeSosId == null && !_sosFired)
                      ? _buildLeftSosButton()
                      : const SizedBox.shrink(),
                ),
              ),

              // Center Partition
              Expanded(
                child: (_activeSosId != null || _sosFired)
                    ? GestureDetector(
                        onTapDown: (_) {
                          _sosHoldTicks = 0;
                          _sosHoldTimer = Timer.periodic(
                            const Duration(milliseconds: 100),
                            (timer) {
                              if (mounted) {
                                setState(() {
                                  _sosHoldTicks++;
                                  if (_sosHoldTicks >= 50) {
                                    _sosHoldTimer?.cancel();
                                    _cancelSOS();
                                  }
                                });
                              }
                            },
                          );
                        },
                        onTapUp: (_) => _cancelHold(),
                        onTapCancel: () => _cancelHold(),
                        onTap: widget.onSosTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 24,
                            horizontal: 16,
                          ),
                          color: Colors.transparent,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (_sosHoldTicks > 0)
                                Positioned.fill(
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: progress,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.2,
                                        ),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                  ),
                                ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _sosHoldTicks > 0
                                                ? 'RELEASING...'
                                                : 'SOS ACTIVE',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 18,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _sosHoldTicks > 0
                                                ? 'Release in ${(5.0 - (_sosHoldTicks / 10)).toStringAsFixed(1)}s'
                                                : 'Hold 5s to cancel',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )
                    : GestureDetector(
                        onTapDown: (_) {
                          if (_sosFired || _validationInProgress) return;
                          _sosHoldTicks = 0;
                          _sosHoldTimer = Timer.periodic(
                            const Duration(milliseconds: 100),
                            (timer) {
                              if (mounted) {
                                setState(() {
                                  _sosHoldTicks++;
                                  if (_sosHoldTicks >= 50) {
                                    _sosHoldTimer?.cancel();
                                    _startValidatedSosFlow();
                                  }
                                });
                              }
                            },
                          );
                        },
                        onTapUp: (_) => _cancelHold(),
                        onTapCancel: () => _cancelHold(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 24,
                            horizontal: 16,
                          ),
                          color: Colors.transparent,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (!_sosFired && _sosHoldTicks > 0)
                                Positioned.fill(
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: progress,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: AppColors.criticalRed.withValues(
                                          alpha: 0.2,
                                        ),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                  ),
                                ),
                              AnimatedScale(
                                scale: _sosHoldTicks > 0 ? 1.06 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              _validationInProgress
                                                  ? 'VALIDATING...'
                                                  : 'HOLD FOR SOS',
                                              style: const TextStyle(
                                                color: AppColors.criticalRed,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 18,
                                                letterSpacing: 1.5,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              _validationInProgress
                                                  ? 'Quick AI check in progress'
                                                  : (_sosHoldTicks > 0)
                                                  ? 'Holding... ${(5.0 - (_sosHoldTicks / 10)).toStringAsFixed(1)}s'
                                                  : 'Hold 5s for help',
                                              style: TextStyle(
                                                color: Colors.black54,
                                                fontSize: 12,
                                                fontWeight: _sosHoldTicks > 0
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),

              // Right Partition
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width:
                      (_sosHoldTicks == 0 && _activeSosId == null && !_sosFired)
                      ? 64
                      : 0,
                  child:
                      (_sosHoldTicks == 0 && _activeSosId == null && !_sosFired)
                      ? _buildRightMapButton()
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
        if (_activeSosId != null || _sosFired)
          ValueListenableBuilder<SosSyncStatus>(
            valueListenable: SosSyncEngine.instance.syncStatusNotifier,
            builder: (context, status, _) {
              if (status.phase == SosSyncPhase.idle) {
                if (_activeSosId != null) {
                  return const _SyncStatusStrip(
                    icon: Icons.check_circle,
                    color: AppColors.primaryGreen,
                    message: 'SOS delivered to all responders',
                  );
                }
                return const _SyncStatusStrip(
                  icon: Icons.wifi_off,
                  color: Colors.orange,
                  message: 'Offline — waiting for connection...',
                  showPulse: true,
                );
              }

              switch (status.phase) {
                case SosSyncPhase.connecting:
                  return _SyncStatusStrip(
                    icon: Icons.sync,
                    color: Colors.orange,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.syncing:
                  return _SyncStatusStrip(
                    icon: Icons.cloud_upload,
                    color: Colors.blue,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.waitingRetry:
                  return _SyncStatusStrip(
                    icon: Icons.timer,
                    color: Colors.orange,
                    message: status.message,
                    showPulse: true,
                  );
                case SosSyncPhase.synced:
                  return _SyncStatusStrip(
                    icon: Icons.check_circle,
                    color: AppColors.primaryGreen,
                    message: status.message,
                  );
                case SosSyncPhase.failed:
                  return _SyncStatusStrip(
                    icon: Icons.error,
                    color: AppColors.criticalRed,
                    message: status.message,
                  );
                default:
                  return const SizedBox.shrink();
              }
            },
          ),
      ],
    );
  }
}

class _SyncStatusStrip extends StatelessWidget {
  const _SyncStatusStrip({
    required this.icon,
    required this.color,
    required this.message,
    this.showPulse = false,
  });

  final IconData icon;
  final Color color;
  final String message;
  final bool showPulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (showPulse) _PulsingDot(color: color),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.3 + (_controller.value * 0.7),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}
