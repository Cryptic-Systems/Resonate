part of 'music_provider.dart';

/// Defers Android effects activation until playback has established its session.
///
/// Kept off the source-load/play critical path because awaiting effect parameter
/// discovery during startup has crashed the Activity on some target devices.
extension MusicProviderAudioEffectsLifecycle on MusicProvider {
  Future<void> syncSavedAudioEffects() async {
    // The controller is backed by Android effects created with EnginePair.
    // Touching it while Media3 is injected would lazily construct the retired
    // just_audio decks just to synchronize effects that Media3 owns separately.
    if (_media3ProviderSession != null || _legacyEnginesRetired) return;
    try {
      await _audioEffectsController.syncAll();
    } catch (e) {
      debugPrint('Saved audio effects sync failed: $e');
    }
  }

  Future<void> _enableEffects(
    dynamic player,
    dynamic eq,
    dynamic loud,
  ) async {
    // Once Media3 owns playback, its active-session observer in
    // AudioEffectsProvider is the only permitted session-attach path. Do not
    // reattach native effects to a stopped legacy EnginePair deck.
    if (_media3ProviderSession != null || _legacyEnginesRetired) return;
    // Preserve the existing delay and fire-and-forget behavior for the
    // legacy engine, including a final authority check after the delay.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (_media3ProviderSession != null || _legacyEnginesRetired) return;
      try {
        await _audioEffectsController.activateFor(player);
      } catch (e) {
        debugPrint('deferred enableEffects failed: $e');
      }
    }));
  }
}
