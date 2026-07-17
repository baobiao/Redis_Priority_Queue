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
 * Mirrors test_bash/integration/test_pq_peek.sh: non-destructive peek. Single mode
 * returns exactly what dequeue would lease next and mutates nothing; top-N returns
 * the front members regardless of lease state with their lease fields; count>size
 * returns all; empty/all-leased -> null/empty; dangling members are skipped (never
 * removed); peek works on a DLQ-shaped queue.
 */
class PqPeekTest {

  // Single mode + single==next-dequeue + top-N + count>size, sharing one queue.
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void singleTopNAndCountOverSize(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{pk}", pfx = "pq:{pk}:m:";
      j.del(q, pfx + "A", pfx + "B", pfx + "C");
      // Front order by (priority, seq): B(pri5), A(pri10,seq1), C(pri10,seq3).
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "A"), "A", "1", "Priority", "10", "Payload", "PAY-A");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "B"), "B", "2", "Priority", "5", "Payload", "PAY-B");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "C"), "C", "3", "Priority", "10", "Payload", "PAY-C");

      // --- Single mode: returns the front deliverable (B), mutating nothing ---
      Object out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-B"), "single peek returns front message B");
      assertFalse(Pq.deep(out).contains("PAY-A"), "single peek returns only one record (no A)");
      assertEquals("0", j.hget(pfx + "B", "ReadAttempts"), "peek did not mutate B ReadAttempts");
      assertEquals("0", j.hget(pfx + "B", "DirtyBit"), "peek did not mutate B DirtyBit");
      assertEquals("0", j.hget(pfx + "B", "ReadDateTime"), "peek did not mutate B ReadDateTime");

      // --- Single peek == the message a subsequent dequeue leases ---
      Object deq = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(deq).contains("PAY-B"), "dequeue leases the same message peek showed (B)");
      assertEquals("1", j.hget(pfx + "B", "DirtyBit"), "dequeue DID mutate B (now in-flight)");

      // --- Top-N mode: front N regardless of lease state (B now in-flight) ---
      out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "2000", "30000", "3");
      assertTrue(Pq.deep(out).contains("PAY-B"), "top-N includes B (in-flight)");
      assertTrue(Pq.deep(out).contains("PAY-A"), "top-N includes A");
      assertTrue(Pq.deep(out).contains("PAY-C"), "top-N includes C");

      // --- count greater than queue size returns all, no error ---
      out = Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "2000", "30000", "100");
      assertTrue(Pq.deep(out).contains("PAY-A"), "count>size returns all (A)");
      assertTrue(Pq.deep(out).contains("PAY-C"), "count>size returns all (C)");
    }
  }

  // --- Empty queue: single -> null, top-N -> empty ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void emptyQueue(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String eq = "pq:{pke}", epfx = "pq:{pke}:m:";
      j.del(eq);
      Object out = Pq.fcallRo(j, "pq_peek", List.of(eq, epfx), "1000", "30000");
      assertEquals("", Pq.deep(out), "empty queue single peek -> null");
      out = Pq.fcallRo(j, "pq_peek", List.of(eq, epfx), "1000", "30000", "5");
      assertFalse(Pq.deep(out).contains("member"), "empty queue top-N peek -> no records");
    }
  }

  // --- All-leased/unexpired: single peek -> null (nothing deliverable) ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void allLeasedSingleNull(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String lq = "pq:{pkl}", lpfx = "pq:{pkl}:m:";
      j.del(lq, lpfx + "Z");
      Pq.fcall(j, "pq_enqueue", List.of(lq, lpfx + "Z"), "Z", "1", "Priority", "5", "Payload", "PAY-Z");
      Pq.fcall(j, "pq_dequeue", List.of(lq, lpfx), "1000", "30000"); // lease Z (unexpired)
      Object out = Pq.fcallRo(j, "pq_peek", List.of(lq, lpfx), "1001", "30000");
      assertEquals("", Pq.deep(out), "all-leased single peek -> null");
    }
  }

  // --- Dangling member is skipped and never removed (read-only) ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void danglingMemberSkippedNeverRemoved(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String dq = "pq:{pkd}", dpfx = "pq:{pkd}:m:";
      j.del(dq, dpfx + "D");
      Pq.fcall(j, "pq_enqueue", List.of(dq, dpfx + "D"), "D", "1", "Priority", "5", "Payload", "PAY-D");
      String mD = String.format("%020d:%s", 1, "D");
      j.del(dpfx + "D"); // Hash gone -> dangling member
      Object out = Pq.fcallRo(j, "pq_peek", List.of(dq, dpfx), "1000", "30000", "5");
      assertFalse(Pq.deep(out).contains("PAY-D"), "top-N skips the dangling member");
      assertEquals(5.0, (double) j.zscore(dq, mD), "peek did NOT remove the dangling member");
    }
  }

  // --- Peek works on a DLQ-shaped queue (same shape as a source queue) ---
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void dlqShapedQueue(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String dl = "dlq:{pk2}", dlpfx = "dlq:{pk2}:m:";
      j.del(dl, dlpfx + "W");
      Pq.fcall(j, "pq_enqueue", List.of(dl, dlpfx + "W"), "W", "1", "Priority", "9", "Payload", "PAY-W");
      Object out = Pq.fcallRo(j, "pq_peek", List.of(dl, dlpfx), "1000", "30000");
      assertTrue(Pq.deep(out).contains("PAY-W"), "peek inspects a DLQ-shaped queue");
    }
  }
}
