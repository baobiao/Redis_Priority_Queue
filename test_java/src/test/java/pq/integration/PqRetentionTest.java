package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_retention.sh: DLQ retention. Dead-lettering
 * stamps DeadLetteredAt=now; pq_reap permanently removes (member + Hash) entries
 * older than the retention window and keeps within-window ones; it is bounded by
 * `limit` (truncated flag); it cleans dangling members; and pq_redrive clears
 * DeadLetteredAt.
 */
class PqRetentionTest {

  // --- Dead-letter stamps DeadLetteredAt; reap keeps within-window then removes ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void stampAndReapWindow(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{rt}", pfx = "pq:{rt}:m:", dl = "dlq:{rt}";
      j.del(q, dl, pfx + "7");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "7"), "7", "7", "Priority", "5", "Payload", "job");
      String m7 = String.format("%020d:%s", 7, "7");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "1"); // RA 0<1 -> leased, RA=1
      Pq.fcall(j, "pq_nack", List.of(pfx + "7"), "1");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "100000", "30000", "0", "1"); // RA=1>=1 -> dead-lettered at now=100000
      assertEquals("100000", j.hget(pfx + "7", "DeadLetteredAt"), "dead-letter stamps DeadLetteredAt=now");
      assertEquals(5.0, (double) j.zscore(dl, m7), "in DLQ before reap");
      // now=120000: age 20000 < 30000 -> kept.
      Object out = Pq.fcall(j, "pq_reap", List.of(dl, pfx), "120000", "30000", "100");
      assertTrue(Pq.deep(out).contains("removed"), "within-window reap removes 0");
      assertEquals(5.0, (double) j.zscore(dl, m7), "kept: still in DLQ");
      // now=140000: age 40000 >= 30000 -> removed (member + Hash).
      out = Pq.fcall(j, "pq_reap", List.of(dl, pfx), "140000", "30000", "100");
      assertTrue(Pq.deep(out).contains("removed"), "expired reap reports removed");
      assertNull(j.zscore(dl, m7), "removed from DLQ");
      assertFalse(j.exists(pfx + "7"), "message Hash deleted");
    }
  }

  // --- Bounded by limit: 3 expired entries, limit=2 -> truncated, then drain ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void boundedByLimit(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q2 = "pq:{rb}", pfx2 = "pq:{rb}:m:", dl2 = "dlq:{rb}";
      j.del(q2, dl2, pfx2 + "1", pfx2 + "2", pfx2 + "3");
      for (int i = 1; i <= 3; i++) {
        Pq.fcall(j, "pq_create", List.of(pfx2 + i),
            "Priority", "5", "Payload", "p" + i, "DeadLetteredAt", "100000");
        j.zadd(dl2, 5, String.format("%020d:%s", i, String.valueOf(i)));
      }
      Object out = Pq.fcall(j, "pq_reap", List.of(dl2, pfx2), "200000", "1000", "2");
      assertTrue(Pq.deep(out).contains("truncated"), "bounded reap examined at most limit -> truncated");
      assertEquals(1L, j.zcard(dl2), "DLQ down to 1 after first bounded reap");
      Pq.fcall(j, "pq_reap", List.of(dl2, pfx2), "200000", "1000", "2");
      assertEquals(0L, j.zcard(dl2), "DLQ drained after second reap");
    }
  }

  // --- Dangling DLQ member (Hash missing) is cleaned up ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void danglingMemberCleaned(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q3 = "pq:{rd}", pfx3 = "pq:{rd}:m:", dl3 = "dlq:{rd}";
      j.del(q3, dl3);
      j.zadd(dl3, 5, String.format("%020d:%s", 9, "9")); // member with no Hash
      Pq.fcall(j, "pq_reap", List.of(dl3, pfx3), "200000", "1000", "100");
      assertEquals(0L, j.zcard(dl3), "dangling member cleaned from DLQ");
    }
  }

  // --- Redrive clears DeadLetteredAt ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void redriveClearsDeadLetteredAt(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q4 = "pq:{rr}", pfx4 = "pq:{rr}:m:", dl4 = "dlq:{rr}";
      j.del(q4, dl4, pfx4 + "5");
      Pq.fcall(j, "pq_create", List.of(pfx4 + "5"),
          "Priority", "5", "Payload", "z", "DeadLetteredAt", "100000");
      String m5 = String.format("%020d:%s", 5, "5");
      j.zadd(dl4, 5, m5);
      Pq.fcall(j, "pq_redrive", List.of(dl4, q4, pfx4 + "5"), m5);
      assertEquals("0", j.hget(pfx4 + "5", "DeadLetteredAt"), "redrive clears DeadLetteredAt to 0");
      assertEquals(5.0, (double) j.zscore(q4, m5), "redriven message back in source");
    }
  }
}
