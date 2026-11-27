import 'package:flutter_test/flutter_test.dart';
import 'package:resonate/services/voice_cue_router.dart';

void main() {
  late DateTime now;
  late VoiceCueRouter router;

  setUp(() {
    now = DateTime.utc(2026, 11, 27, 10);
    router = VoiceCueRouter(clock: () => now);
  });

  VoiceCueRequest request({
    VoiceCueRoute route = VoiceCueRoute.bothContextual,
    VoiceCueOrigin origin = VoiceCueOrigin.playerAuto,
    String cueId = 'cue.test',
    String eventId = 'event-1',
    String semanticGroup = 'acknowledgement',
    bool enabled = true,
    bool confirmed = true,
    DateTime? expiresAt,
  }) {
    return VoiceCueRequest(
      cueId: cueId,
      route: route,
      origin: origin,
      eventId: eventId,
      semanticGroup: semanticGroup,
      voiceFeedbackEnabled: enabled,
      confirmed: confirmed,
      expiresAt: expiresAt ?? now.add(const Duration(seconds: 5)),
    );
  }

  test('player-only cue is accepted only from automatic playback', () {
    expect(
      router.evaluate(request(route: VoiceCueRoute.playerAuto)).allowed,
      isTrue,
    );
    expect(
      router.evaluate(request(
        route: VoiceCueRoute.playerAuto,
        origin: VoiceCueOrigin.djManual,
        eventId: 'manual-event',
      )).reason,
      VoiceCueBlockReason.wrongWorkspace,
    );
  });

  test('manual-only cue is accepted only from DJ Workspace/Console events', () {
    expect(
      router.evaluate(request(
        route: VoiceCueRoute.djManual,
        origin: VoiceCueOrigin.djManual,
      )).allowed,
      isTrue,
    );
    expect(
      router.evaluate(request(
        route: VoiceCueRoute.djManual,
        origin: VoiceCueOrigin.playerAuto,
        eventId: 'auto-event',
      )).reason,
      VoiceCueBlockReason.wrongWorkspace,
    );
  });

  test('contextual shared phrase can be used in either experience', () {
    expect(router.evaluate(request(origin: VoiceCueOrigin.playerAuto)).allowed,
        isTrue);
    expect(router.evaluate(request(
      origin: VoiceCueOrigin.djManual,
      eventId: 'dj-event',
    )).allowed, isTrue);
  });

  test('shared system cue requires shared-system event origin', () {
    expect(router.evaluate(request(
      route: VoiceCueRoute.sharedSystem,
      origin: VoiceCueOrigin.sharedSystem,
    )).allowed, isTrue);
    expect(router.evaluate(request(
      route: VoiceCueRoute.sharedSystem,
      origin: VoiceCueOrigin.playerAuto,
      eventId: 'player-event',
    )).reason, VoiceCueBlockReason.wrongWorkspace);
  });

  test('does not speak when feedback is disabled or event is unconfirmed', () {
    expect(router.evaluate(request(enabled: false)).reason,
        VoiceCueBlockReason.voiceFeedbackDisabled);
    expect(router.evaluate(request(
      confirmed: false,
      eventId: 'unconfirmed',
    )).reason, VoiceCueBlockReason.unconfirmedEvent);
  });

  test('rejects expired cue before it is played', () {
    expect(router.evaluate(request(
      expiresAt: now,
    )).reason, VoiceCueBlockReason.expired);
  });

  test('rejects missing runtime IDs before reserving an event group', () {
    expect(router.evaluate(request(cueId: '  ')).reason,
        VoiceCueBlockReason.invalidRequest);
    expect(router.evaluate(request(
      eventId: '  ',
      semanticGroup: 'another-group',
    )).reason, VoiceCueBlockReason.invalidRequest);
    expect(router.evaluate(request(
      eventId: 'valid-after-invalid',
    )).allowed, isTrue);
  });

  test('releases a reservation when playback does not start', () {
    expect(router.evaluate(request()).allowed, isTrue);
    expect(router.evaluate(request()).reason,
        VoiceCueBlockReason.duplicateEvent);
    expect(router.release(
      eventId: 'event-1',
      semanticGroup: 'acknowledgement',
    ), isTrue);
    expect(router.evaluate(request()).allowed, isTrue);
  });

  test('only one phrase from a semantic group is accepted per event', () {
    expect(router.evaluate(request()).allowed, isTrue);
    expect(router.evaluate(request(
      eventId: 'event-1',
      semanticGroup: 'acknowledgement',
    )).reason, VoiceCueBlockReason.duplicateEvent);
    expect(router.evaluate(request(
      eventId: 'event-1',
      semanticGroup: 'transition_praise',
    )).allowed, isTrue);
  });

  test('session reset clears duplicate suppression', () {
    expect(router.evaluate(request()).allowed, isTrue);
    router.resetSession();
    expect(router.evaluate(request()).allowed, isTrue);
  });
}
