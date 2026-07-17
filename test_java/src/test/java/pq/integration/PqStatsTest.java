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
 * Mirrors test_bash/integration/test_pq_stats.sh: pq_stats. Exact depths + front
 * Priority (cheap tier); a bounded breakdown classifies the scanned front as
 * available / in-flight / delayed with a truncated flag; an approximate
 * oldest-dead-letter age; and it mutates nothing.
 */
class PqStatsTest {

  // Cheap tier, bounded breakdown, no-mutation, truncated flag, and oldest-age.
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void depthsBreakdownAndAge(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{st}", pfx = "pq:{st}:m:", dl = "dlq:{st}";
      j.del(q, dl, pfx + "A", pfx + "B", pfx + "C", pfx + "D");
      // A available (pri5), B available (pri10), C delayed (VisibleAt future), D will be leased.
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "A"), "A", "1", "Priority", "5", "Payload", "a");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "B"), "B", "2", "Priority", "10", "Payload", "b");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "C"),
          "C", "3", "Priority", "10", "Payload", "c", "VisibleAt", "999999");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "D"), "D", "4", "Priority", "20", "Payload", "d");
      // Dequeue once leases the front deliverable (A). A in-flight; B available; C delayed; D available.
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");

      // --- Cheap tier: exact depths + front Priority ---
      Object out = Pq.fcallRo(j, "pq_stats", List.of(q, pfx, dl), "2000", "30000");
      assertTrue(Pq.deep(out).contains("depth"), "cheap: depth reported");
      assertTrue(Pq.deep(out).contains("4"), "cheap: queue depth = 4");
      assertTrue(Pq.deep(out).contains("front_priority"), "cheap: front_priority label");

      // --- Bounded breakdown: A in-flight, B available, C delayed, D available ---
      out = Pq.fcallRo(j, "pq_stats", List.of(q, pfx, dl), "2000", "30000", "100");
      assertTrue(Pq.deep(out).contains("available"), "breakdown: available label");
      assertTrue(Pq.deep(out).contains("in_flight"), "breakdown: in_flight label");
      assertTrue(Pq.deep(out).contains("delayed"), "breakdown: delayed label");
      assertTrue(Pq.deep(out).contains("truncated"), "breakdown: truncated label");
      // exact counts: available=2 (B,D), in_flight=1 (A), delayed=1 (C)
      assertTrue(Pq.deep(out).contains("available 2"), "available=2 (B,D)");

      // --- No mutation: A still leased (DirtyBit=1), others untouched ---
      assertEquals("1", j.hget(pfx + "A", "DirtyBit"), "stats did not mutate A (DirtyBit=1)");
      assertEquals("999999", j.hget(pfx + "C", "VisibleAt"), "stats did not mutate C VisibleAt");

      // --- Truncated flag when depth > max_scan ---
      out = Pq.fcallRo(j, "pq_stats", List.of(q, pfx, dl), "2000", "30000", "2");
      assertTrue(Pq.deep(out).contains("truncated 1"), "truncated=1 when depth>max_scan");

      // --- Approximate oldest-dead-letter age from the scanned DLQ prefix ---
      j.del(pfx + "X");
      Pq.fcall(j, "pq_create", List.of(pfx + "X"),
          "Priority", "5", "Payload", "x", "DeadLetteredAt", "1000");
      j.zadd(dl, 5, String.format("%020d:%s", 9, "X"));
      out = Pq.fcallRo(j, "pq_stats", List.of(q, pfx, dl), "5000", "30000", "100");
      assertTrue(Pq.deep(out).contains("oldest_dead_letter_age"), "age: oldest_dead_letter_age label");
      // age = now(5000) - DeadLetteredAt(1000) = 4000
      assertTrue(Pq.deep(out).contains("oldest_dead_letter_age 4000"), "oldest age = 4000");
    }
  }

  // --- Empty queue: zero depths, front_priority -1 ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void emptyQueue(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String eq = "pq:{se}", epfx = "pq:{se}:m:";
      j.del(eq);
      Object out = Pq.fcallRo(j, "pq_stats", List.of(eq, epfx), "1000", "30000");
      assertTrue(Pq.deep(out).contains("0"), "empty queue: depth 0");
      assertTrue(Pq.deep(out).contains("-1"), "empty queue: front_priority -1");
    }
  }
}
