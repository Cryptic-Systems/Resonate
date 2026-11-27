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
    List<VoiceCueOrigin>? allowedOrigins,
  }) => VoiceCueRequest(
        cueId: cueId,
        route: route,
        origin: origin,
        eventId: eventId,
        semanticGroup: semanticGroup,
        voiceFeedbackEnabled: enabled,
        confirmed: confirmed,
        expiresAt: expiresAt ?? now.add(const Duration(seconds: 5)),
        allowedOrigins: allowedOrigins,
      );

  test('player-only cue is accepted only from automatic playback', () {
    expect(router.evaluate(request(route: VoiceCueRoute.playerAuto)).allowed, isTrue);
    expect(router.evaluate(request(
      route: VoiceCueRoute.playerAuto,
      origin: VoiceCueOrigin.djManual,
      eventId: 'manual-event',
    )).reason, VoiceCueBlockReason.wrongWorkspace);
  });

  test('manual-only cue is accepted only from DJ Workspace/Console events', () {
    expect(router.evaluate(request(
      route: VoiceCueRoute.djManual,
      origin: VoiceCueOrigin.djManual,
    )).allowed, isTrue);
    expect(router.evaluate(request(
      route: VoiceCueRoute.djManual,
      origin: VoiceCueOrigin.playerAuto,
      eventId: 'auto-event',
    )).reason, VoiceCueBlockReason.wrongWorkspace);
  });

  test('contextual shared phrase can be used in either experience', () {
    expect(router.evaluate(request(origin: VoiceCueOrigin.playerAuto)).allowed, isTrue);
    expect(router.evaluate(request(
      origin: VoiceCueOrigin.djManual,
      eventId: 'dj-event',
    )).allowed, isTrue);
  });

  test('conditional cue can explicitly permit shared-system origin', () {
    expect(router.evaluate(request(
      route: VoiceCueRoute.conditional,
      origin: VoiceCueOrigin.sharedSystem,
      allowedOrigins: const [VoiceCueOrigin.playerAuto, VoiceCueOrigin.sharedSystem],
    )).allowed, isTrue);
    expect(router.evaluate(request(
      route: VoiceCueRoute.conditional,
      origin: VoiceCueOrigin.sharedSystem,
      eventId: 'conditional-default',
    )).reason, VoiceCueBlockReason.wrongWorkspace);
    expect(router.evaluate(request(
      route: VoiceCueRoute.conditional,
      origin: VoiceCueOrigin.sharedSystem,
      allowedOrigins: const [],
      eventId: 'conditional-empty',
    )).reason, VoiceCueBlockReason.invalidRequest);
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

  test('origin allow-list cannot override fixed route permissions', () {
    expect(router.evaluate(request(
      route: VoiceCueRoute.playerAuto,
      origin: VoiceCueOrigin.sharedSystem,
      allowedOrigins: const [VoiceCueOrigin.sharedSystem],
    )).reason, VoiceCueBlockReason.wrongWorkspace);
  });

  test('expired dedupe reservation is pruned and can be reused', () {
    expect(router.evaluate(request(expiresAt: now.add(const Duration(seconds: 1)))).allowed, isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(router.evaluate(request()).allowed, isTrue);
  });

  test('bounded cache evicts oldest remembered event', () {
    for (var i = 0; i < 513; i++) {
      expect(router.evaluate(request(eventId: 'event-$i')).allowed, isTrue);
    }
    expect(router.evaluate(request(eventId: 'event-0')).allowed, isTrue);
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
    expect(router.evaluate(request(expiresAt: now)).reason,
        VoiceCueBlockReason.expired);
  });

  test('rejects missing runtime IDs before reserving an event group', () {
    expect(router.evaluate(request(cueId: '  ')).reason,
        VoiceCueBlockReason.invalidRequest);
    expect(router.evaluate(request(
      eventId: '  ',
      semanticGroup: 'another-group',
    )).reason, VoiceCueBlockReason.invalidRequest);
    expect(router.evaluate(request(eventId: 'valid-after-invalid')).allowed, isTrue);
  });

  test('releases a reservation when playback does not start', () {
    expect(router.evaluate(request()).allowed, isTrue);
    expect(router.evaluate(request()).reason, VoiceCueBlockReason.duplicateEvent);
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

  test('event and group boundaries cannot collide in dedupe key', () {
    expect(router.evaluate(request(
      eventId: 'a::b',
      semanticGroup: 'c',
    )).allowed, isTrue);
    expect(router.evaluate(request(
      eventId: 'a',
      semanticGroup: 'b::c',
    )).allowed, isTrue);
  });

  test('session reset clears duplicate suppression', () {
    expect(router.evaluate(request()).allowed, isTrue);
    router.resetSession();
    expect(router.evaluate(request()).allowed, isTrue);
  });
}
