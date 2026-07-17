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
 * Mirrors test_bash/integration/test_pq_dequeue_priority_interleave.sh: messages enqueued
 * WHILE a consumer is actively consuming. A higher-priority arrival is delivered on the next
 * acquire ahead of a lower-priority arrival, but NEITHER preempts the message already
 * in-flight. Priority is delivery order among AVAILABLE (un-leased) messages, and each
 * acquire re-scans the queue from the front. All "now" values are caller-supplied ARGV.
 * Spec: priority-then-FIFO ordering + concurrent lease visibility (US1).
 */
class PqDequeuePriorityInterleaveTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void priorityInterleaveDoesNotPreemptInflight(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{pi1}";
      String pfx = "pq:{pi1}:m:";
      j.del(q, pfx + "A", pfx + "B", pfx + "C");

      // A is the only message initially: seq1, Priority 10.
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "A"), "A", "1", "Priority", "10", "Payload", "PAY-A");

      // Consumer acquires A -> A is now in-flight (DirtyBit=1, ReadAttempts=1, ReadDateTime=1000).
      Object dA = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(dA).contains("PAY-A"), "acquire 1 leases A (the only message)");
      assertEquals("1",    j.hget(pfx + "A", "DirtyBit"),     "A leased: DirtyBit=1");
      assertEquals("1",    j.hget(pfx + "A", "ReadAttempts"), "A leased: ReadAttempts=1");
      assertEquals("1000", j.hget(pfx + "A", "ReadDateTime"), "A leased: ReadDateTime=1000");

      // While A is IN-FLIGHT, enqueue a HIGHER-priority (B, pri5) and a LOWER-priority (C, pri20).
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "B"), "B", "2", "Priority", "5",  "Payload", "PAY-B");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "C"), "C", "3", "Priority", "20", "Payload", "PAY-C");
      assertEquals(3L, j.zcard(q), "queue now holds 3 members");

      // Next acquire must return the NEW higher-priority B (jumps ahead of C), must NOT
      // re-deliver the leased A, and must NOT skip to the lower-priority C.
      Object dB = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1001", "30000");
      assertTrue(Pq.deep(dB).contains("PAY-B"),  "acquire 2 = new higher-priority B");
      assertFalse(Pq.deep(dB).contains("PAY-A"), "acquire 2 does not re-deliver leased A");
      assertFalse(Pq.deep(dB).contains("PAY-C"), "acquire 2 does not jump to lower-priority C");

      // The higher-priority arrival must NOT have preempted the in-flight A.
      assertEquals("1",    j.hget(pfx + "A", "DirtyBit"),     "A still in-flight, not preempted: DirtyBit=1");
      assertEquals("1",    j.hget(pfx + "A", "ReadAttempts"), "A ReadAttempts unchanged (1)");
      assertEquals("1000", j.hget(pfx + "A", "ReadDateTime"), "A ReadDateTime unchanged (1000)");

      // With A and B both leased, the lower-priority C is delivered last.
      Object dC = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1002", "30000");
      assertTrue(Pq.deep(dC).contains("PAY-C"),  "acquire 3 = lower-priority C (A,B leased)");
      assertFalse(Pq.deep(dC).contains("PAY-A"), "acquire 3 does not re-deliver A");
      assertFalse(Pq.deep(dC).contains("PAY-B"), "acquire 3 does not re-deliver B");

      // All three now leased and unexpired -> nothing available (null, not empty payload).
      Object dNull = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1003", "30000");
      assertEquals("", Pq.deep(dNull), "acquire 4 returns null (all three leased)");
    }
  }
}
