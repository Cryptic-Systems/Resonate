/// Resolves the duration used by the DJ deck timeline and waveform overview.
///
/// The library duration is also the identity used by persisted waveform chunks,
/// so it is authoritative when available. Media3 duration is the fallback while
/// library metadata is unavailable (for example, during initial deck prepare).
class DjConsoleDurationPolicy {
  const DjConsoleDurationPolicy();

  Duration resolve({Duration? libraryDuration, Duration? mediaDuration}) {
    if (libraryDuration != null && libraryDuration > Duration.zero) {
      return libraryDuration;
    }
    if (mediaDuration != null && mediaDuration > Duration.zero) {
      return mediaDuration;
    }
    return Duration.zero;
  }
}
