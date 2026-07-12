package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_scheduled.sh: scheduled delivery via
 * VisibleAt (not-before). A future VisibleAt is skipped by dequeue until now >= it,
 * then delivered normally; a not-yet-visible high-priority message does not block a
 * visible lower-priority one; VisibleAt=0/absent is immediately visible.
 */
class PqScheduledTest {

  // --- Future VisibleAt: skipped before, delivered at/after (boundary now==VisibleAt) ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void futureVisibleAtSkippedThenDelivered(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{sc}", pfx = "pq:{sc}:m:";
      j.del(q, pfx + "A");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "A"),
          "A", "1", "Priority", "5", "Payload", "PAY-A", "VisibleAt", "5000");
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "4999", "30000");
      assertEquals("", Pq.deep(out), "not visible yet (now<VisibleAt) -> null");
      assertEquals("0", j.hget(pfx + "A", "DirtyBit"), "skipped message not leased: DirtyBit=0");
      assertEquals("0", j.hget(pfx + "A", "ReadAttempts"), "skipped message not leased: ReadAttempts=0");
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "5000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-A"), "visible at now==VisibleAt (>=) -> delivered");
    }
  }

  // --- A not-yet-visible HIGH-priority message does not block a visible LOWER-priority one ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void hiddenHighPriorityDoesNotBlockVisibleLow(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{sd}", pfx = "pq:{sd}:m:";
      j.del(q, pfx + "H", pfx + "L");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "H"),
          "H", "1", "Priority", "5", "Payload", "PAY-H", "VisibleAt", "5000");  // higher prio, hidden
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "L"),
          "L", "2", "Priority", "10", "Payload", "PAY-L", "VisibleAt", "0");    // lower prio, visible
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-L"),
          "visible low-priority L delivered while high-priority H is hidden");
      assertFalse(Pq.deep(out).contains("PAY-H"), "hidden H must not be delivered early");
      // Once H is visible it takes precedence (higher priority) over any remaining visible message.
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "5000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-H"), "H delivered once visible");
    }
  }

  // --- VisibleAt = 0 (and omitted) are immediately visible ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void visibleAtZeroAndOmitted(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{s0}", pfx = "pq:{s0}:m:";
      j.del(q, pfx + "Z", pfx + "Y");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "Z"),
          "Z", "1", "Priority", "5", "Payload", "PAY-Z", "VisibleAt", "0");
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1", "30000");
      assertTrue(Pq.deep(out).contains("PAY-Z"), "explicit VisibleAt=0 is immediately visible");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "Y"),
          "Y", "2", "Priority", "5", "Payload", "PAY-Y"); // no VisibleAt field
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1", "30000");
      assertTrue(Pq.deep(out).contains("PAY-Y"), "omitted VisibleAt defaults to immediately visible");
    }
  }
}
