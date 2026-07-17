package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_deadletter.sh: dead-letter at dequeue
 * (SQS-style max-receive cap). An available message whose ReadAttempts >= cap is
 * moved to the DLQ (index-only) instead of being leased; an unexpired in-flight
 * message is never dead-lettered; an expired-lease over-cap message is; a below-cap
 * message is delivered; omitting the DLQ/cap reproduces Feature 003 exactly.
 */
class PqDeadletterTest {

  // ---- Scenario A: cap reached -> moved to the DLQ, not delivered ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void scenarioA_capReachedMovedToDlq(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dlA}", pfx = "pq:{dlA}:m:", dl = "dlq:{dlA}";
      j.del(q, dl, pfx + "A");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "A"), "A", "1", "Priority", "5", "Payload", "PAY-A");
      String mA = String.format("%020d:%s", 1, "A");
      // Two deliver-then-nack cycles bring ReadAttempts to 2 (= cap).
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "2");
      Pq.fcall(j, "pq_nack", List.of(pfx + "A"), "1");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "2000", "30000", "0", "2");
      Pq.fcall(j, "pq_nack", List.of(pfx + "A"), "2");
      assertEquals("2", j.hget(pfx + "A", "ReadAttempts"), "A at cap: ReadAttempts=2");
      // Next dead-letter dequeue: A is available (DirtyBit=0) and ReadAttempts>=cap -> DLQ.
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "3000", "30000", "0", "2");
      assertEquals("", Pq.deep(out), "poison A not delivered (null reply)");
      assertEquals(5.0, (double) j.zscore(dl, mA), "A moved to DLQ at score=Priority");
      assertNull(j.zscore(q, mA), "A removed from the source");
      assertEquals("PAY-A", j.hget(pfx + "A", "Payload"), "A message Hash untouched (Payload)");
    }
  }

  // ---- Scenario B: a below-cap message is delivered normally ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void scenarioB_belowCapDelivered(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dlB}", pfx = "pq:{dlB}:m:", dl = "dlq:{dlB}";
      j.del(q, dl, pfx + "B");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "B"), "B", "1", "Priority", "5", "Payload", "PAY-B");
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "2");
      assertTrue(Pq.deep(out).contains("PAY-B"), "below-cap B is leased and returned");
      String mB = String.format("%020d:%s", 1, "B");
      assertNull(j.zscore(dl, mB), "B NOT dead-lettered");
    }
  }

  // ---- Scenario C: over-cap but in-flight/unexpired is NOT dead-lettered;
  //      the same message once its lease EXPIRES is dead-lettered ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void scenarioC_inflightNotDeadletteredUntilExpired(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dlC}", pfx = "pq:{dlC}:m:", dl = "dlq:{dlC}";
      j.del(q, dl, pfx + "C");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "C"), "C", "1", "Priority", "5", "Payload", "PAY-C");
      String mC = String.format("%020d:%s", 1, "C");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "2"); // RA=1, in-flight
      Pq.fcall(j, "pq_nack", List.of(pfx + "C"), "1");                            // RA=1, DirtyBit=0
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "2000", "30000", "0", "2"); // RA=2, in-flight, RDT=2000
      assertEquals("1", j.hget(pfx + "C", "DirtyBit"), "C in-flight after 2nd lease: DirtyBit=1");
      // now=2001: lease NOT expired (1ms < 30000) and RA>=cap -> C must be skipped, not dead-lettered.
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "2001", "30000", "0", "2");
      assertEquals("", Pq.deep(out), "unexpired in-flight over-cap yields null");
      assertNull(j.zscore(dl, mC), "C NOT dead-lettered while in-flight");
      assertEquals(5.0, (double) j.zscore(q, mC), "C still in the source queue");
      // now=40000: lease expired (38000ms >= 30000) and RA>=cap -> C is dead-lettered.
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "40000", "30000", "0", "2");
      assertEquals("", Pq.deep(out), "expired-lease over-cap yields null");
      assertEquals(5.0, (double) j.zscore(dl, mC), "C moved to DLQ once lease expired");
      assertNull(j.zscore(q, mC), "C removed from the source");
    }
  }

  // ---- Scenario E: Feature 003 parity -- omitting DLQ/cap never dead-letters ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void scenarioE_f003ParityNoDlqNeverDeadletters(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dlE}", pfx = "pq:{dlE}:m:";
      j.del(q, pfx + "E");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "E"), "E", "1", "Priority", "5", "Payload", "PAY-E");
      String mE = String.format("%020d:%s", 1, "E");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      Pq.fcall(j, "pq_nack", List.of(pfx + "E"), "1");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "2000", "30000");
      Pq.fcall(j, "pq_nack", List.of(pfx + "E"), "2");
      // ReadAttempts=2, but the 2-key call has no cap -> must lease, never dead-letter.
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "3000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-E"),
          "2-key dequeue still delivers an over-cap message (F003 parity)");
      assertEquals(5.0, (double) j.zscore(q, mE), "E remains in the source (not dead-lettered)");
    }
  }

  // ---- Scenario F: a member already present in the DLQ is not duplicated (FR-005) ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void scenarioF_noDuplicateInDlq(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dlF}", pfx = "pq:{dlF}:m:", dl = "dlq:{dlF}";
      j.del(q, dl, pfx + "F");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "F"), "F", "1", "Priority", "7", "Payload", "PAY-F");
      String mF = String.format("%020d:%s", 1, "F");
      j.zadd(dl, 7, mF); // simulate prior DLQ presence
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "2");
      Pq.fcall(j, "pq_nack", List.of(pfx + "F"), "1");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "2000", "30000", "0", "2");
      Pq.fcall(j, "pq_nack", List.of(pfx + "F"), "2");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "3000", "30000", "0", "2"); // dead-letter F (already in DLQ)
      assertEquals(1L, j.zcard(dl), "DLQ still holds exactly one F member (no duplicate)");
      assertNull(j.zscore(q, mF), "F removed from the source");
    }
  }
}
