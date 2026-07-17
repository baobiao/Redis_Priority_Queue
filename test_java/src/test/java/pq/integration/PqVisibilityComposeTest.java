package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_visibility_compose.sh: VisibleAt
 * composition. read exposes VisibleAt; a pre-005 5-field message reads/dequeues as
 * VisibleAt=0 (no error); peek single skips a not-yet-visible front message while
 * top-N reports it with VisibleAt; a not-yet-visible over-cap message is
 * dead-lettered only once visible; redrive resets VisibleAt to 0.
 */
class PqVisibilityComposeTest {

  // --- read exposes VisibleAt ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void readExposesVisibleAt(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{cm}:m:1");
      Pq.fcall(j, "pq_create", List.of("q:{cm}:m:1"),
          "Priority", "5", "Payload", "hi", "VisibleAt", "90000");
      Object out = Pq.fcallRo(j, "pq_read", List.of("q:{cm}:m:1"));
      assertTrue(Pq.deep(out).contains("VisibleAt"), "read includes VisibleAt label");
      assertTrue(Pq.deep(out).contains("90000"), "read includes VisibleAt value");
    }
  }

  // --- Back-compat: a message stored with only the 5 original fields ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void backCompatFiveFieldMessage(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{bc}", pfx = "pq:{bc}:m:";
      j.del(q, pfx + "old");
      j.hset(pfx + "old", Map.of(
          "ReadAttempts", "0", "DirtyBit", "0", "ReadDateTime", "0", "Priority", "5", "Payload", "OLD"));
      String mold = String.format("%020d:%s", 1, "old");
      j.zadd(q, 5, mold);
      Object out = Pq.fcallRo(j, "pq_read", List.of(pfx + "old"));
      assertTrue(Pq.deep(out).contains("OLD"), "legacy 5-field message reads without error (Payload)");
      assertTrue(Pq.deep(out).contains("VisibleAt"), "legacy message reports VisibleAt=0");
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1", "30000");
      assertTrue(Pq.deep(out).contains("OLD"), "legacy message is immediately visible (dequeued)");
    }
  }

  // --- Peek: single skips not-yet-visible; top-N reports it with VisibleAt ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void peekSingleSkipsTopNReports(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{pv}", pfx = "pq:{pv}:m:";
      j.del(q, pfx + "F");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "F"),
          "F", "1", "Priority", "5", "Payload", "PAY-F", "VisibleAt", "8000");
      Object out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "7999", "30000");
      assertEquals("", Pq.deep(out), "single peek skips not-yet-visible -> null");
      out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "7999", "30000", "10");
      assertTrue(Pq.deep(out).contains("PAY-F"), "top-N reports the not-yet-visible member");
      assertTrue(Pq.deep(out).contains("8000"), "top-N record carries VisibleAt");
      out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "8000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-F"), "single peek returns it once visible");
    }
  }

  // --- Dead-letter deferred until visible, then redrive resets VisibleAt to 0 ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void deadLetterDeferredThenRedriveResets(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{dv}", pfx = "pq:{dv}:m:", dl = "dlq:{dv}";
      j.del(q, dl, pfx + "M");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "M"), "M", "1", "Priority", "5", "Payload", "PAY-M");
      String mM = String.format("%020d:%s", 1, "M");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "1"); // RA 0<1 -> leased, RA=1
      Pq.fcall(j, "pq_nack", List.of(pfx + "M"), "1", "5000");                    // RA=1(=cap), hidden until 5000
      Object out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "4999", "30000", "0", "1");
      assertEquals("", Pq.deep(out), "over-cap but not-yet-visible -> null (not dead-lettered)");
      assertNull(j.zscore(dl, mM), "M NOT dead-lettered while hidden");
      assertEquals(5.0, (double) j.zscore(q, mM), "M still in the source while hidden");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "5000", "30000", "0", "1"); // now visible + over cap -> DLQ
      assertEquals(5.0, (double) j.zscore(dl, mM), "M dead-lettered once visible");
      assertNull(j.zscore(q, mM), "M removed from the source");

      // --- Redrive resets VisibleAt to 0 ---
      out = Pq.fcall(j, "pq_redrive", List.of(dl, q, pfx + "M"), mM);
      assertEquals("OK", Pq.deep(out), "redrive returns OK");
      assertEquals("0", j.hget(pfx + "M", "VisibleAt"), "redrive reset VisibleAt to 0");
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1", "30000");
      assertTrue(Pq.deep(out).contains("PAY-M"), "redriven message is immediately deliverable");
    }
  }
}
