package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_retry_backoff.sh: retry backoff via nack
 * with a future VisibleAt. A nacked message with a delay is not redelivered until
 * now >= VisibleAt, then redelivered with ReadAttempts retained across the delay; a
 * plain nack is unchanged (Feature 003 parity); fencing intact.
 */
class PqRetryBackoffTest {

  // --- Nack with a backoff hides the message until now >= VisibleAt ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void backoffDelaysRedelivery(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{bo}", pfx = "pq:{bo}:m:";
      j.del(q, pfx + "1");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "1"), "1", "1", "Priority", "5", "Payload", "work");

      // Lease at now=1000 (ReadAttempts=1), then nack with a backoff to VisibleAt=5000.
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      Object out = Pq.fcall(j, "pq_nack", List.of(pfx + "1"), "1", "5000");
      assertEquals("OK", Pq.deep(out), "nack-with-delay returns OK");
      assertEquals("0", j.hget(pfx + "1", "DirtyBit"), "released: DirtyBit=0");
      assertEquals("5000", j.hget(pfx + "1", "VisibleAt"), "VisibleAt set to 5000");
      assertEquals("1", j.hget(pfx + "1", "ReadAttempts"), "ReadAttempts retained (1)");
      assertEquals("1000", j.hget(pfx + "1", "ReadDateTime"), "ReadDateTime retained (1000)");

      // Before the backoff elapses -> not redelivered.
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "4999", "30000");
      assertEquals("", Pq.deep(out), "not redelivered before VisibleAt -> null");

      // At/after the backoff -> redelivered, ReadAttempts incremented from the retained value.
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "5000", "30000");
      assertTrue(Pq.deep(out).contains("work"), "redelivered at VisibleAt");
      assertEquals("2", j.hget(pfx + "1", "ReadAttempts"), "ReadAttempts incremented to 2");
    }
  }

  // --- A plain nack (no VisibleAt) is unchanged from Feature 003; fencing intact ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void plainNackImmediateAndFencing(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{bp}", pfx = "pq:{bp}:m:";
      j.del(q, pfx + "2");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "2"), "2", "1", "Priority", "5", "Payload", "w2");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      Pq.fcall(j, "pq_nack", List.of(pfx + "2"), "1"); // no delay
      assertEquals("0", j.hget(pfx + "2", "VisibleAt"), "plain nack leaves VisibleAt at default 0");
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1001", "30000");
      assertTrue(Pq.deep(out).contains("w2"), "plain-nacked message immediately available (F003 parity)");

      // Fencing still applies to a nack-with-delay: a stale token is rejected.
      Pq.assertError("EFENCED", () -> Pq.fcall(j, "pq_nack", List.of(pfx + "2"), "999", "5000"));
    }
  }
}
