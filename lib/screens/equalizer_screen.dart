import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/audio_effects_provider.dart';
import '../providers/equalizer_provider.dart';
import '../models/resonate_sound_profile.dart';
import '../services/audio_effects_bridge.dart';
import 'dsp_live_meter_policy.dart';
import 'dsp_settings_screen.dart';

/// Glass Equalizer — packed, creative, readable for everyone.
class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  final ValueNotifier<DspLiveMeterSnapshot?> _liveMeters =
      ValueNotifier<DspLiveMeterSnapshot?>(null);
  Timer? _meterTimer;
  bool _meterPollInFlight = false;

  // Resonate brand accents (logo: blue / violet / pink / orange)
  static const _cBlue = Color(0xFF5B8CFF);
  static const _cViolet = Color(0xFF9B6DFF);
  static const _cPink = Color(0xFFFF6BB5);
  static const _cOrange = Color(0xFFFF8A4C);

  String _profileDescription(String name) => switch (name) {
        'Resonate Signature' => 'The smooth, balanced Resonate foundation.',
        'Resonate Warmth' => 'A little body and softness for long sessions.',
        'Resonate Clarity' => 'Bring detail and presence forward.',
        'Resonate Afterhours' => 'Gentle, relaxed listening late in the day.',
        'Resonate Pulse' => 'Rhythm with a lively, controlled lift.',
        'Resonate Deep Bass' => 'Deeper low-end weight without a huge bass shelf.',
        'Resonate Drive' => 'A steady, clear balance for the road.',
        'Resonate Focus' => 'Keep voices and detail clear at a calm level.',
        'Resonate Speaker' => 'A modest balance for small speaker playback.',
        'Resonate Vocal Presence' => 'Put vocals closer without over-brightening.',
        'Resonate Subforge' => 'Sub-bass extension, kick impact and a defined upper-mid edge.',
        'Resonate Midrange Atlas' => 'More body, vocal fundamentals and clear presence across the mids.',
        'Resonate Titan Pulse' => 'A powerful low end with forward, energetic mids.',
        'Resonate Velvet Drive' => 'Warm low-mid weight and smooth instrument body.',
        _ => 'A Resonate-crafted listening profile.',
      };

  IconData _profileIcon(String name) => switch (name) {
        'Resonate Signature' => Icons.auto_awesome_rounded,
        'Resonate Warmth' => Icons.wb_twilight_rounded,
        'Resonate Clarity' => Icons.diamond_outlined,
        'Resonate Afterhours' => Icons.nights_stay_rounded,
        'Resonate Pulse' => Icons.favorite_rounded,
        'Resonate Deep Bass' => Icons.graphic_eq_rounded,
        'Resonate Drive' => Icons.directions_car_filled_rounded,
        'Resonate Focus' => Icons.center_focus_strong_rounded,
        'Resonate Speaker' => Icons.speaker_rounded,
        'Resonate Vocal Presence' => Icons.mic_rounded,
        'Resonate Subforge' => Icons.waves_rounded,
        'Resonate Midrange Atlas' => Icons.graphic_eq_rounded,
        'Resonate Titan Pulse' => Icons.bolt_rounded,
        'Resonate Velvet Drive' => Icons.album_rounded,
        _ => Icons.graphic_eq_rounded,
      };

  Color _profileColor(String name) => switch (name) {
        'Resonate Signature' => _cBlue,
        'Resonate Warmth' => _cOrange,
        'Resonate Clarity' => const Color(0xFF57D6C2),
        'Resonate Afterhours' => _cViolet,
        'Resonate Pulse' => _cPink,
        'Resonate Deep Bass' => const Color(0xFF4D79FF),
        'Resonate Drive' => const Color(0xFFFF9A5C),
        'Resonate Focus' => const Color(0xFF70B8A5),
        'Resonate Speaker' => const Color(0xFFB38AFF),
        'Resonate Vocal Presence' => const Color(0xFFFF78A8),
        'Resonate Subforge' => const Color(0xFF4B91E8),
        'Resonate Midrange Atlas' => const Color(0xFF42B9A5),
        'Resonate Titan Pulse' => const Color(0xFFFF765F),
        'Resonate Velvet Drive' => const Color(0xFFB88A64),
        _ => _cBlue,
      };

  Future<void> _pollLiveMeters() async {
    if (_meterPollInFlight || !mounted) return;
    _meterPollInFlight = true;
    try {
      final status = await AudioEffectsBridge.getLiveDspStatus();
      if (!mounted) return;
      _liveMeters.value = DspLiveMeterSnapshot.fromNativeStatus(status);
    } catch (_) {
      if (mounted) _liveMeters.value = null;
    } finally {
      _meterPollInFlight = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _pollLiveMeters();
    _meterTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollLiveMeters(),
    );
  }

  @override
  void dispose() {
    _meterTimer?.cancel();
    _liveMeters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Equalizer'),
        actions: [
          IconButton(
            tooltip: 'DSP engine settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DspSettingsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'How to use',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => _showHelp(context),
          ),
          PopupMenuButton<String>(
            tooltip: 'Sound profile backup',
            icon: const Icon(Icons.import_export_rounded),
            onSelected: (action) {
              if (action == 'export') {
                _exportSoundProfiles(context);
              } else if (action == 'import') {
                _importSoundProfiles(context);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.copy_rounded),
                  title: Text('Copy profile backup JSON'),
                ),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.content_paste_rounded),
                  title: Text('Import profile backup JSON'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Save custom profile',
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: () => _saveCustom(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Soft brand wash
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          const Color(0xFF0E0B18),
                          _cViolet.withValues(alpha: 0.18),
                          _cBlue.withValues(alpha: 0.12),
                          const Color(0xFF0A0A12),
                        ]
                      : [
                          scheme.surface,
                          _cBlue.withValues(alpha: 0.08),
                          _cPink.withValues(alpha: 0.06),
                          scheme.surface,
                        ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Consumer<EqualizerProvider>(
              builder: (context, eq, _) {
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                  children: [
                    ValueListenableBuilder<DspLiveMeterSnapshot?>(
                      valueListenable: _liveMeters,
                      builder: (context, snapshot, _) =>
                          _LiveDspMeterPanel(snapshot: snapshot),
                    ),
                    const SizedBox(height: 16),

                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Resonate sound',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Original profiles for a sound or a listening environment.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          _buildProfileGrid(
                            context,
                            eq,
                            eq.builtInSoundProfiles
                                .where((profile) => profile.category != 'Resonate Advanced')
                                .toList(),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Advanced sound profiles',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Full 31-band parametric shaping with tighter filter focus, automatic headroom and peak control.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          _buildProfileGrid(
                            context,
                            eq,
                            eq.advancedSoundProfiles,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),


                    // —— Custom profiles —— 
                    _GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your custom profiles',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                            'Saved profiles preserve your complete DSP configuration, not just the EQ curve.',
                            style: Theme.of(context).textTheme.bodySmall),
                          if (eq.customSoundProfiles.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final profile in eq.customSoundProfiles)
                                  FilterChip(
                                    label: Text(profile.name),
                                    selected: eq.preset == profile.name,
                                    onSelected: eq.isEnabled
                                        ? (_) => _applySoundProfile(context, profile)
                                        : null,
                                    onDeleted: () => eq.deleteCustomPreset(profile.name),
                                    deleteIcon: const Icon(Icons.close, size: 16),
                                  ),
                              ],
                            ),
                          ] else ...[
                            const SizedBox(height: 10),
                            const Text(
                              'No custom profiles yet. Choose a sound profile and use the bookmark icon to save a personal variation.'),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    const SizedBox(height: 20),
                    Text(
                      'Live native DSP readings. Resonate sound profiles, shaped for your listening.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.65),
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSoundProfiles(BuildContext context) async {
    final eq = context.read<EqualizerProvider>();
    try {
      final json = eq.exportSoundProfilesJson();
      await Clipboard.setData(ClipboardData(text: json));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied ${eq.customSoundProfiles.length} complete profile(s) as JSON')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  }

  Future<void> _importSoundProfiles(BuildContext context) async {
    final controller = TextEditingController();
    final source = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import sound profiles'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 8,
              maxLines: 14,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Paste a Resonate sound profile JSON backup',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (source == null || source.trim().isEmpty || !context.mounted) return;
    try {
      final count = await context.read<EqualizerProvider>().importSoundProfilesJson(source);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $count complete sound profile(s)')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import profiles: $error')),
      );
    }
  }

  void _showHelp(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'How to use the Equalizer',
                style: Theme.of(ctx)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              const _HelpStep(
                n: '1',
                title: 'Start with Resonate sound',
                body:
                    'Choose a Resonate sound profile. The live panel above reports measured DSP output separately for each active deck.',
              ),
              const _HelpStep(
                n: '2',
                title: 'Create your sound',
                body:
                    'Choose a profile that matches your listening environment, then save a personal variation with the bookmark button.',
              ),
              const _HelpStep(
                n: '3',
                title: 'Understand your meters',
                body:
                    'The live signal dials show measured input peak, post-EQ peak and short-term RMS. The supporting readouts show native headroom, limiter reduction and applied adaptive gains.',
              ),
              const _HelpStep(
                n: '4',
                title: 'Save your profile',
                body:
                    'Use the bookmark icon to save a named custom sound profile.',
              ),
              const SizedBox(height: 8),
              Text(
                'Engine',
                style: Theme.of(ctx)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Resonate uses its own DSP Engine to shape audio while you listen. '
                'The panel only displays readings supplied by the native engine. '
                'When playback is idle, it waits rather than showing fabricated zero values.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileGrid(
    BuildContext context,
    EqualizerProvider eq,
    List<ResonateSoundProfile> profiles,
  ) {
    return SizedBox(
      height: 326,
      child: GridView.builder(
        scrollDirection: Axis.horizontal,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisExtent: 174,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: profiles.length,
        itemBuilder: (context, index) {
          final profile = profiles[index];
          final accent = _profileColor(profile.name);
          final selected = eq.preset == profile.name;
          return Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: eq.isEnabled
                  ? () => _applySoundProfile(context, profile)
                  : null,
              child: Ink(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: selected ? 0.34 : 0.20),
                      Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
                    ],
                  ),
                  border: Border.all(
                    color: selected ? accent : accent.withValues(alpha: 0.38),
                    width: selected ? 1.8 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.20),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(_profileIcon(profile.name), color: accent, size: 20),
                        ),
                        const Spacer(),
                        if (selected)
                          Icon(Icons.check_circle_rounded, color: accent, size: 20),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      profile.name.replaceFirst('Resonate ', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _profileDescription(profile.name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _applySoundProfile(
    BuildContext context,
    ResonateSoundProfile profile,
  ) async {
    try {
      // Update session-bound effects first, then publish the complete sticky
      // DSP snapshot so both current and future A/B decks inherit it.
      await context.read<AudioEffectsProvider>().applySoundProfileSettings(profile.settings);
      await context.read<EqualizerProvider>().applySoundProfile(profile);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Applied sound: ${profile.name}')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not apply sound profile: $error')),
      );
    }
  }

  Future<void> _saveCustom(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save custom profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'My mix',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final eq = context.read<EqualizerProvider>();
    final savedName = await eq.saveCustomPreset(name);
    if (savedName != null) {
      await eq.saveCustomSoundProfile(savedName);
    }
    if (!context.mounted || savedName == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved “$savedName”')),
    );
  }
}

// —— Glass shell ——

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: (isDark ? Colors.white : scheme.surface)
                .withValues(alpha: isDark ? 0.08 : 0.55),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: child,
          ),
        ),
      ),
    );
  }
}


class _LiveDspMeterPanel extends StatelessWidget {
  const _LiveDspMeterPanel({required this.snapshot});

  final DspLiveMeterSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final currentSnapshot = snapshot;
    final decks = currentSnapshot == null
        ? <DspDeckMeterReading>[]
        : currentSnapshot.decks.values.toList()
          ..sort((a, b) => a.deckId.compareTo(b.deckId));
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: const LinearGradient(
                    colors: [_EqualizerScreenState._cBlue, _EqualizerScreenState._cViolet],
                  ),
                ),
                child: const Icon(Icons.multitrack_audio_rounded,
                    color: Colors.white, size: 21),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('LIVE DSP SIGNAL',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900, letterSpacing: 0.7)),
                    Text('Native measurements · independent deck telemetry',
                      style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const _Badge(label: 'REAL-TIME', color: Color(0xFF3DDC97)),
            ],
          ),
          const SizedBox(height: 16),
          if (decks.isEmpty)
            const _NoLiveDspSignal()
          else
            for (var i = 0; i < decks.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _DeckSignalInstrument(
                reading: decks[i],
                isActive: currentSnapshot?.activeDeckId == decks[i].deckId,
              ),
            ],
        ],
      ),
    );
  }
}

class _NoLiveDspSignal extends StatelessWidget {
  const _NoLiveDspSignal();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.48),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.sensors_off_rounded, size: 28, color: color),
          const SizedBox(height: 8),
          Text('Waiting for live DSP readings',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Start playback to populate the instruments. No readings are fabricated while the native engine is idle.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _DeckSignalInstrument extends StatelessWidget {
  const _DeckSignalInstrument({
    required this.reading,
    required this.isActive,
  });

  final DspDeckMeterReading reading;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final accent = reading.deckId == 'A'
        ? const Color(0xFF5B8CFF)
        : const Color(0xFFFF6BB5);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.58),
        border: Border.all(
          color: accent.withValues(alpha: isActive ? 0.78 : 0.30),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? const Color(0xFF3DDC97) : accent,
                  boxShadow: [
                    BoxShadow(
                      color: (isActive ? const Color(0xFF3DDC97) : accent)
                          .withValues(alpha: 0.45),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('DECK ${reading.deckId}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900, letterSpacing: 1.0)),
              const Spacer(),
              Text(isActive ? 'NATIVE ACTIVE DECK' : 'LIVE ENGINE',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: isActive ? const Color(0xFF3DDC97) : accent,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.45)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _SignalDial(
                label: 'INPUT PEAK',
                valueDb: reading.inputPeakDb,
                color: accent,
              ),
              _SignalDial(
                label: 'POST EQ',
                valueDb: reading.postEqPeakDb,
                color: const Color(0xFF9B6DFF),
              ),
              _SignalDial(
                label: 'SHORT RMS',
                valueDb: reading.shortTermRmsDb,
                color: const Color(0xFFFF8A4C),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MeterReadout(label: 'TRUE PEAK', value: _db(reading.inputTruePeakDb)),
              _MeterReadout(label: 'HEADROOM', value: _signedDb(reading.headroomDb)),
              _MeterReadout(label: 'LIMITER GR', value: _db(reading.limiterGrDb)),
              _MeterReadout(label: 'AUTO BASS', value: _signedDb(reading.autoBassAppliedDb)),
              _MeterReadout(label: 'AUTO GAIN', value: _signedDb(reading.autoGainAppliedDb)),
              _MeterReadout(label: 'AUTO PREAMP', value: _signedDb(reading.autoPreampAppliedDb)),
              _MeterReadout(
                label: 'VIRTUAL BASS',
                value: reading.autoVirtualBassApplied == null
                    ? null
                    : '${(reading.autoVirtualBassApplied! * 100).toStringAsFixed(0)}%',
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _db(double? value) =>
      value == null ? null : '${value.toStringAsFixed(1)} dB';

  static String? _signedDb(double? value) {
    if (value == null) return null;
    final prefix = value > 0 ? '+' : '';
    return '$prefix${value.toStringAsFixed(1)} dB';
  }
}

class _SignalDial extends StatelessWidget {
  const _SignalDial({
    required this.label,
    required this.valueDb,
    required this.color,
  });

  final String label;
  final double? valueDb;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final progress = valueDb == null
        ? 0.0
        : DspLiveMeterSnapshot.normalizeDbfs(valueDb!);
    return Expanded(
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, animated, _) => SizedBox(
              width: 76,
              height: 76,
              child: CustomPaint(
                painter: _SignalDialPainter(
                  progress: valueDb == null ? null : animated,
                  color: color,
                ),
                child: Center(
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    size: 21,
                    color: valueDb == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
                        : color,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w800, letterSpacing: 0.25)),
          const SizedBox(height: 2),
          Text(
            valueDb == null ? '—' : '${valueDb!.toStringAsFixed(1)} dBFS',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: valueDb == null
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SignalDialPainter extends CustomPainter {
  const _SignalDialPainter({required this.progress, required this.color});

  final double? progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 6;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.16);
    canvas.drawArc(rect, start, sweep, false, track);
    if (progress == null) return;

    final value = progress!.clamp(0.0, 1.0).toDouble();
    final active = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: [color.withValues(alpha: 0.35), color, Colors.white.withValues(alpha: 0.92)],
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep * value, false, active);
    final angle = start + sweep * value;
    final point = Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
    canvas.drawCircle(point, 4.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SignalDialPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

class _MeterReadout extends StatelessWidget {
  const _MeterReadout({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 88),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w800, letterSpacing: 0.3)),
          const SizedBox(height: 2),
          Text(value ?? '—',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w900,
              fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Text(label, style: TextStyle(
        color: color, fontWeight: FontWeight.w900, fontSize: 10,
        letterSpacing: 0.5)),
    );
  }
}

class _HelpStep extends StatelessWidget {
  const _HelpStep(
      {required this.n, required this.title, required this.body});
  final String n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
            child: Text(n,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

