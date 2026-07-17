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
 * Mirrors test_bash/integration/test_pq_dequeue_visibility.sh: visibility-timeout reclaim
 * + fencing. An unsettled lease is skipped before the timeout and reclaimed after it (all
 * "now" values are caller-supplied ARGV, no real sleeps); the original (stale) token can no
 * longer ack/nack the reacquired message. Spec: FR-003/004/011, SC-006/007.
 */
class PqDequeueVisibilityTest {

  private static String member(long seq, String id) {
    return String.format("%020d:%s", seq, id);
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void visibilityReclaimAndFencing(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{v1}";
      String pfx = "pq:{v1}:m:";
      String member = member(1, "v");
      j.del(q, pfx + "v");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "v"), "v", "1", "Priority", "5", "Payload", "pv");

      // Consumer A leases at now=1000, timeout=30000 (token = ReadAttempts = 1).
      Object d1 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d1).contains("pv"), "A acquires the message");
      assertEquals("1",    j.hget(pfx + "v", "ReadAttempts"), "A: ReadAttempts=1");
      assertEquals("1000", j.hget(pfx + "v", "ReadDateTime"), "A: ReadDateTime=1000");

      // Before the timeout (now=5000, 5000-1000 < 30000): still leased, not returned.
      Object d2 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "5000", "30000");
      assertEquals("", Pq.deep(d2), "before timeout: not reclaimed (null)");

      // At/after the timeout (now=31000, 31000-1000 = 30000 >= 30000): reclaimed by B.
      Object d3 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "31000", "30000");
      assertTrue(Pq.deep(d3).contains("pv"), "after timeout: B reclaims the message");
      assertEquals("2",     j.hget(pfx + "v", "ReadAttempts"), "B: ReadAttempts incremented to 2");
      assertEquals("31000", j.hget(pfx + "v", "ReadDateTime"), "B: ReadDateTime updated to 31000");

      // A's stale token (1) can no longer settle the reacquired message.
      Pq.assertError("EFENCED",
          () -> Pq.fcall(j, "pq_ack", List.of(q, pfx + "v"), member, "1"));
      Pq.assertError("EFENCED",
          () -> Pq.fcall(j, "pq_nack", List.of(pfx + "v"), "1"));
      // B's lease is untouched by the stale attempts.
      assertTrue(j.exists(pfx + "v"), "message still present after stale settles");
      assertEquals("1", j.hget(pfx + "v", "DirtyBit"), "still in-flight (DirtyBit=1)");

      // B settles normally with the current token (2).
      Object ackB = Pq.fcall(j, "pq_ack", List.of(q, pfx + "v"), member, "2");
      assertEquals("OK", Pq.deep(ackB), "B ack with current token -> OK");
      assertFalse(j.exists(pfx + "v"), "message removed after B ack");
      assertEquals(0L, j.zcard(q), "queue member removed after B ack");
    }
  }
}
