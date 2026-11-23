import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/audio_effects_provider.dart';
import 'providers/audio_visualization_provider.dart';
import 'providers/autopilot_controller.dart';
import 'providers/bluetooth_provider.dart';
import 'providers/crossfade_provider.dart';
import 'providers/dj_mode_provider.dart';
import 'providers/equalizer_provider.dart';
import 'experience/experience_provider.dart';
import 'providers/intelligence_provider.dart';
import 'providers/intelligence_mix_controller.dart';
import 'providers/library_provider.dart';
import 'providers/listening_history_provider.dart';
import 'providers/music_provider.dart';
import 'modes/providers/mode_provider.dart';
import 'modes/integration/resonate_mode_ports.dart';
import 'modes/integration/resonate_motion_port.dart';
import 'modes/models/running_intent.dart';
import 'providers/playback_features_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/theme_provider.dart';
import 'navigation/shell_nav.dart';
import 'widgets/ask_resonate/ask_resonate_controller.dart';
import 'screens/home_screen.dart';
import 'screens/experience_selector_screen.dart';
import 'screens/dj_experience_shell.dart';
import 'services/media3_provider_session.dart';
import 'playback/playback_control_arbiter.dart';
import 'services/playback_diagnostics_observer.dart';
import 'services/resonate_diagnostics.dart';

/// Brand spectrum from the Resonate mark: cyan-blue → violet → pink → orange.
class ResonateBrand {
  static const blue = Color(0xFF3D9EFF);
  static const violet = Color(0xFF9A5CFF);
  static const pink = Color(0xFFFF4DB8);
  static const orange = Color(0xFFFF8A3D);
  static const night = Color(0xFF050510);
  static const mist = Color(0xFFF5F2FF);
}

ThemeData _theme(Brightness brightness, {bool pureBlack = false}) {
  final dark = brightness == Brightness.dark;
  final seed = dark ? ResonateBrand.violet : ResonateBrand.blue;

  var scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );

  // Pin the spectrum so UI stays true to the logo, not only seed-derived hues.
  scheme = scheme.copyWith(
    primary: dark ? const Color(0xFFB29BFF) : const Color(0xFF6B4EFF),
    onPrimary: Colors.white,
    primaryContainer: dark ? const Color(0xFF2A1F4D) : const Color(0xFFE8E0FF),
    onPrimaryContainer: dark ? const Color(0xFFE6DEFF) : const Color(0xFF2A1468),
    secondary: dark ? const Color(0xFFFF7AC8) : const Color(0xFFE91E8C),
    onSecondary: Colors.white,
    secondaryContainer: dark ? const Color(0xFF4A1838) : const Color(0xFFFFD6EC),
    onSecondaryContainer: dark ? const Color(0xFFFFD6EC) : const Color(0xFF5C0A3A),
    tertiary: ResonateBrand.orange,
    onTertiary: Colors.white,
    tertiaryContainer: dark ? const Color(0xFF4A2E14) : const Color(0xFFFFE4CC),
    onTertiaryContainer: dark ? const Color(0xFFFFE4CC) : const Color(0xFF4A2200),
    surface: dark ? const Color(0xFF0C0C14) : ResonateBrand.mist,
    surfaceContainerLowest: dark ? ResonateBrand.night : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF14141E) : const Color(0xFFEEEAFF),
    surfaceContainer: dark ? const Color(0xFF1A1A26) : const Color(0xFFE6E0F7),
    surfaceContainerHigh: dark ? const Color(0xFF222230) : const Color(0xFFDDD5F2),
    surfaceContainerHighest: dark ? const Color(0xFF2A2A3A) : const Color(0xFFD4CAED),
    outline: dark ? const Color(0xFF5A5670) : const Color(0xFF9B92B8),
    outlineVariant: dark ? const Color(0xFF3A3650) : const Color(0xFFCDC4E4),
  );

  if (pureBlack && dark) {
    scheme = scheme.copyWith(
      surface: const Color(0xFF000000),
      onSurface: const Color(0xFFE8E8E8),
      surfaceContainerLowest: const Color(0xFF000000),
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF121212),
      surfaceContainerHigh: const Color(0xFF1A1A1A),
      surfaceContainerHighest: const Color(0xFF222222),
    );
  }

  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: pureBlack && dark ? const Color(0xFF000000) : null,
  );
  final onSurface = scheme.onSurface;
  final muted = scheme.onSurfaceVariant;
  final text = base.textTheme.copyWith(
    displaySmall: base.textTheme.displaySmall?.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      color: onSurface,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: onSurface,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      color: onSurface,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: onSurface,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: 16,
      height: 1.35,
      color: onSurface,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.35,
      color: muted,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      height: 1.3,
      color: muted,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: onSurface,
    ),
  );

  final radius = BorderRadius.circular(18);

  return base.copyWith(
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor:
        pureBlack && dark ? const Color(0xFF000000) : scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface.withValues(alpha: 0.92),
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: scheme.surface,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: scheme.surface,
            ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStatePropertyAll(text.labelLarge),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: scheme.primary, size: 24);
        }
        return IconThemeData(color: muted, size: 24);
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.secondary,
      foregroundColor: scheme.onSecondary,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.primaryContainer,
      labelStyle: text.labelLarge?.copyWith(fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return scheme.onPrimary;
        return scheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return scheme.primary;
        return scheme.surfaceContainerHighest;
      }),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.secondary,
      overlayColor: scheme.secondary.withValues(alpha: 0.16),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Capture framework and uncaught asynchronous failures in the local flight
  // recorder, while preserving Flutter's normal error presentation.
  FlutterError.onError = (details) {
    unawaited(ResonateDiagnostics.recordCrash(
      details.exception,
      details.stack ?? StackTrace.current,
      source: 'flutter_framework',
    ));
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(ResonateDiagnostics.recordCrash(
      error,
      stack,
      source: 'platform_dispatcher',
    ));
    return false; // Keep the platform's normal uncaught-error handling.
  };

  // Preserve normal console output while adding a sanitized local copy to the
  // flight recorder. This captures plugin/native warnings routed via debugPrint.
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    originalDebugPrint(message, wrapWidth: wrapWidth);
    if (message != null && message.trim().isNotEmpty) {
      unawaited(ResonateDiagnostics.record('debug_log', {
        'message': message,
      }));
    }
  };

  await ResonateDiagnostics.record('app_started', {
    'buildMode': kDebugMode ? 'debug' : kProfileMode ? 'profile' : 'release',
    'platform': defaultTargetPlatform.name,
    'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
    'viewCount': ui.PlatformDispatcher.instance.views.length,
  });
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const ResonateApp());
}

class ResonateApp extends StatelessWidget {
  const ResonateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<PlaybackControlArbiter>(
          create: (_) => PlaybackControlArbiter(
            onDiagnostic: (event) {
              unawaited(ResonateDiagnostics.record('playback_control_arbiter', {
                'type': event.type.name,
                'generation': event.generation,
                'owner': event.owner,
                'priority': event.priority?.name,
                'operation': event.operation,
                'otherOwner': event.otherOwner,
                'reason': event.reason,
              }));
            },
          ),
          dispose: (_, arbiter) => unawaited(arbiter.close()),
        ),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => ExperienceProvider()),
        ChangeNotifierProvider(create: (_) => ShellNav()),
        ChangeNotifierProvider(create: (_) => AskResonateController()),
        ChangeNotifierProvider(
          create: (context) {
            final provider = MusicProvider(
              media3ProviderSession: Media3ProviderSession(),
              playbackControlArbiter: context.read<PlaybackControlArbiter>(),
              deferMedia3UntilSettingsReady: true,
            );
            // Media3 starts after persisted DSP and playback settings are restored.
            return provider;
          },
        ),
        ChangeNotifierProvider(
          create: (context) =>
              IntelligenceProvider(music: context.read<MusicProvider>()),
        ),
        ChangeNotifierProvider(
          create: (context) => IntelligenceMixController(
            music: context.read<MusicProvider>(),
            intelligence: context.read<IntelligenceProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) =>
              PlaybackDiagnosticsObserver(music: context.read<MusicProvider>()),
        ),
        ChangeNotifierProvider(create: (_) => BluetoothProvider()),
        ChangeNotifierProvider(
          create: (context) {
            final modes = ModeProvider();
            modes.attachPlayback(
              ResonateModePlaybackPort(context.read<MusicProvider>()),
            );
            modes.attachMediaSource(const ResonateModeMediaSourcePort());
            modes.attachContext(
              ResonateModeContextPort(context.read<BluetoothProvider>()),
            );
            final music = context.read<MusicProvider>();
            modes.attachMotion(
              ResonateMotionPort(),
              isPlaying: () => music.isPlaying,
              onIntent: (intent) {
                if (intent.type == RunningIntentType.suggestPause) {
                  unawaited(music.pause(source: 'running_automation'));
                } else if (intent.type == RunningIntentType.suggestResume) {
                  unawaited(music.resumePlayback(source: 'running_automation'));
                }
              },
            );
            music.attachModes(modes);
            context.read<IntelligenceProvider>().attachModes(modes);
            return modes;
          },
        ),
        ChangeNotifierProvider(
          create: (context) => AutopilotController(
            music: context.read<MusicProvider>(),
            intelligence: context.read<IntelligenceProvider>(),
            modes: context.read<ModeProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) => EqualizerProvider(
            music: context.read<MusicProvider>(),
            bluetooth: context.read<BluetoothProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) {
            final music = context.read<MusicProvider>();
            return AudioEffectsProvider(
              // DSP/session-bound effects follow the same canonical Media3
              // session as transport and state after the provider handoff.
              playbackSession: music.media3PlaybackSession,
              playbackControlArbiter: music.playbackControlArbiter,
            );
          },
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) =>
              CrossfadeProvider(music: context.read<MusicProvider>()),
        ),
        ChangeNotifierProvider(
          create: (context) =>
              DjModeProvider(music: context.read<MusicProvider>()),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) =>
              PlaybackFeaturesProvider(music: context.read<MusicProvider>()),
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (context) {
            final music = context.read<MusicProvider>();
            return AudioVisualizationProvider()
              ..bindPlayback(
                listenable: music,
                isPlaying: () => music.isPlaying,
              );
          },
        ),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => PlaylistProvider()),
        ChangeNotifierProvider(create: (_) => ListeningHistoryProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          title: 'Resonate',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(
            Brightness.dark,
            pureBlack: themeProvider.pureBlack,
          ),
          themeMode: themeProvider.useSystemTheme
              ? ThemeMode.system
              : (themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light),
          home: const _LifecycleHome(),
        ),
      ),
    );
  }
}

class _LifecycleHome extends StatefulWidget {
  const _LifecycleHome();

  @override
  State<_LifecycleHome> createState() => _LifecycleHomeState();
}

class _LifecycleHomeState extends State<_LifecycleHome>
    with WidgetsBindingObserver {
  BluetoothProvider? _bluetooth;
  LibraryProvider? _library;
  Timer? _analysisOpportunityTimer;
  String? _lastBluetoothSignature;
  int? _lastLibrarySongCount;
  bool _wasLibraryScanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Install the barrier before any screen can issue a transport command.
    final startupSettingsReady = Future.wait<void>([
      context.read<EqualizerProvider>().ready,
      context.read<AudioEffectsProvider>().ready,
      context.read<PlaybackFeaturesProvider>().ready,
    ]);
    context.read<MusicProvider>().setStartupSettingsReady(startupSettingsReady);
    unawaited(startupSettingsReady.then((_) async {
      if (!mounted) return;
      await context.read<MusicProvider>().prepareMedia3ProviderSession();
    }).catchError((Object error, StackTrace stack) {
      debugPrint('Media3 startup after settings restore failed: $error');
      debugPrint('$stack');
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final foreground = WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;
      try {
        context.read<DjModeProvider>().setAppForeground(foreground);
      } catch (_) {}
      if (foreground) _startForegroundAnalysisOpportunities();
      try {
        if (foreground) {
          context.read<DjModeProvider>().onAnalysisOpportunity('app_started');
        }
      } catch (_) {}
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<BluetoothProvider>();
    if (identical(next, _bluetooth)) return;
    _bluetooth?.removeListener(_onBluetoothChanged);
    _bluetooth = next;
    _lastBluetoothSignature = _bluetoothSignature(next);
    next.addListener(_onBluetoothChanged);

    final library = context.read<LibraryProvider>();
    if (!identical(library, _library)) {
      _library?.removeListener(_onLibraryChanged);
      _library = library;
      _lastLibrarySongCount = library.allSongs.length;
      _wasLibraryScanning = library.isScanning;
      library.addListener(_onLibraryChanged);
    }
  }

  void _onLibraryChanged() {
    final library = _library;
    if (library == null) return;
    final count = library.allSongs.length;
    final scanFinished = _wasLibraryScanning && !library.isScanning;
    final libraryChanged = _lastLibrarySongCount != count;
    _wasLibraryScanning = library.isScanning;
    _lastLibrarySongCount = count;
    if (!scanFinished && !libraryChanged) return;
    unawaited(ResonateDiagnostics.record('library_scan_state', {
      'songCount': count,
      'scanFinished': scanFinished,
      'isScanning': library.isScanning,
    }));
    try {
      context.read<DjModeProvider>().onAnalysisOpportunity('library_changed');
    } catch (_) {}
  }

  String _bluetoothSignature(BluetoothProvider provider) =>
      '${provider.bluetoothConnected}|${provider.connectedDeviceName}|${provider.audioContext.name}';

  void _onBluetoothChanged() {
    final bluetooth = _bluetooth;
    if (bluetooth == null) return;
    final signature = _bluetoothSignature(bluetooth);
    if (signature == _lastBluetoothSignature) return;
    _lastBluetoothSignature = signature;
    unawaited(ResonateDiagnostics.record('audio_route_state_changed', {
      'bluetoothConnected': bluetooth.bluetoothConnected,
      'deviceNamePresent': (bluetooth.connectedDeviceName ?? '').isNotEmpty,
      'audioContext': bluetooth.audioContext.name,
    }));
    try {
      context.read<DjModeProvider>().onAnalysisOpportunity('audio_route_changed');
    } catch (_) {}
  }

  void _startForegroundAnalysisOpportunities() {
    _analysisOpportunityTimer?.cancel();
    _analysisOpportunityTimer = Timer.periodic(
      const Duration(minutes: 20),
      (_) {
        try {
          context.read<DjModeProvider>().onAnalysisOpportunity(
                'foreground_idle_window',
              );
        } catch (_) {}
      },
    );
  }

  void _stopForegroundAnalysisOpportunities() {
    _analysisOpportunityTimer?.cancel();
    _analysisOpportunityTimer = null;
  }

  @override
  void dispose() {
    _stopForegroundAnalysisOpportunities();
    _bluetooth?.removeListener(_onBluetoothChanged);
    _library?.removeListener(_onLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final music = context.read<MusicProvider>();
    unawaited(ResonateDiagnostics.record('app_lifecycle', {
      'state': state.name,
      'songId': music.currentSong?.id,
      'positionMs': music.currentPosition.inMilliseconds,
      'isPlaying': music.isPlaying,
      'queueIndex': music.queueIndex,
      'queueLength': music.queue.length,
      'repeatMode': music.repeatMode.name,
      'crossfadeEnabled': music.crossfadeEnabled,
      'transitionInProgress': music.transitionInProgress,
    }));
    final djMode = context.read<DjModeProvider>();
    djMode.setAppForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<MusicProvider>().onAppForegrounded());
      _startForegroundAnalysisOpportunities();
      try {
        context.read<DjModeProvider>().onAnalysisOpportunity('app_resumed');
      } catch (_) {}
      return;
    }
    _stopForegroundAnalysisOpportunities();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      try {
        context.read<MusicProvider>().onAppBackgrounded();
      } catch (_) {}
    }
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(ResonateDiagnostics.record('app_memory_pressure', {
      'songId': context.read<MusicProvider>().currentSong?.id,
      'isPlaying': context.read<MusicProvider>().isPlaying,
      'lifecycleState': WidgetsBinding.instance.lifecycleState?.name,
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ExperienceProvider>(
      builder: (context, experience, _) {
        if (!experience.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (experience.needsInitialSelection) {
          return const ExperienceSelectorScreen();
        }
        return switch (experience.selected!) {
          ResonateExperience.player => const HomeScreen(),
          ResonateExperience.resonatixDj => const DjExperienceShell(),
        };
      },
    );
  }
}
