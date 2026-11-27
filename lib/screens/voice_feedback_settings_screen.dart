import 'dart:async';

import 'package:flutter/material.dart';

import '../services/voice_cue_service.dart';
import '../services/voice_cue_router.dart';
import '../ui/resonate_glass.dart';

class VoiceFeedbackSettingsScreen extends StatefulWidget {
  const VoiceFeedbackSettingsScreen({super.key});

  @override
  State<VoiceFeedbackSettingsScreen> createState() =>
      _VoiceFeedbackSettingsScreenState();
}

class _VoiceFeedbackSettingsScreenState
    extends State<VoiceFeedbackSettingsScreen> {
  bool _enabled = true;
  bool _loading = true;
  bool _testing = false;
  String? _testStatus;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final enabled = await VoiceCueService.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await VoiceCueService.instance.setEnabled(value);
    if (value) {
      unawaited(VoiceCueService.instance.speak(
        cueId: 'system_consent_status.voice_system_voice_feedback_enabled',
        origin: VoiceCueOrigin.sharedSystem,
        eventId: 'voice_feedback_enabled_${DateTime.now().microsecondsSinceEpoch}',
        confirmed: true,
        allowedOrigins: const <VoiceCueOrigin>[VoiceCueOrigin.sharedSystem],
      ));
    }
  }

  Future<void> _testVoice() async {
    setState(() {
      _testing = true;
      _testStatus = null;
    });
    final started = await VoiceCueService.instance.speak(
      cueId: 'system_consent_status.voice_system_ready',
      origin: VoiceCueOrigin.sharedSystem,
      eventId: 'voice_feedback_test_${DateTime.now().microsecondsSinceEpoch}',
      confirmed: true,
      allowedOrigins: const <VoiceCueOrigin>[VoiceCueOrigin.sharedSystem],
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testStatus = started
          ? 'Test cue started. You should hear “Ready”.'
          : 'The test cue could not start. Check the voice-cue diagnostics.';
    });
  }

  @override
  Widget build(BuildContext context) => ResonateGlassScaffold(
        title: const Text('Voice feedback'),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
          children: [
            ResonateGlassCard(
              blurEnabled: false,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.record_voice_over_rounded),
                title: const Text('Voice cues'),
                subtitle: Text(_loading
                    ? 'Loading preference…'
                    : _enabled
                        ? 'Short Resonate phrases can accompany confirmed Player, Mode and DJ events.'
                        : 'Voice cues are muted. Music playback is unaffected.'),
                value: _enabled,
                onChanged: _loading ? null : _setEnabled,
              ),
            ),
            const SizedBox(height: 12),
            ResonateGlassCard(
              blurEnabled: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: _loading || !_enabled || _testing ? null : _testVoice,
                    icon: _testing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.volume_up_rounded),
                    label: Text(_testing ? 'Testing voice…' : 'Test voice feedback'),
                  ),
                  if (_testStatus != null) ...[
                    const SizedBox(height: 10),
                    Text(_testStatus!),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            const ResonateGlassCard(
              blurEnabled: false,
              child: Text(
                'Voice cues use the original recordings and preserve their dynamics, including intentionally quiet delivery. They do not normalize your music or take over the music transport.',
              ),
            ),
          ],
        ),
      );
}
