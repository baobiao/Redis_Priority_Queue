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
 * Mirrors test_bash/integration/test_pq_dequeue_roundtrip.sh: acquire in priority then
 * FIFO order, lease fields set, Payload fidelity, null on empty; ack removes (idempotent
 * NOOP on retry); nack releases and the message is redelivered with ReadAttempts retained.
 * All timestamps are caller-supplied ARGV (no real sleeps).
 * Spec: FR-002/003/004/005/006/009/010/012, SC-001/002/004/005/009.
 */
class PqDequeueRoundtripTest {

  private static String member(long seq, String id) {
    return String.format("%020d:%s", seq, id);
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void dequeueAckNackRoundTrip(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{d1}";
      String pfx = "pq:{d1}:m:";
      j.del(q, pfx + "a", pfx + "b", pfx + "c");

      // a: seq1 pri10 ; b: seq2 pri5 ; c: seq3 pri10  -> delivery order b, a, c.
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "a"), "a", "1", "Priority", "10", "Payload", "task-a");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "b"), "b", "2", "Priority", "5",  "Payload", "task-b");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "c"), "c", "3", "Priority", "10", "Payload", "task-c");

      // Priority then FIFO order.
      Object d1 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d1).contains("task-b"), "1st acquire = highest priority (b, pri5)");
      Object d2 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d2).contains("task-a"), "2nd acquire = a (pri10, seq1 before c)");
      Object d3 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d3).contains("task-c"), "3rd acquire = c (pri10, seq3)");

      // All in-flight -> null (distinct from an empty payload).
      Object d4 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertEquals("", Pq.deep(d4), "4th acquire returns null (all leased)");

      // Lease fields set on the acquired message b.
      assertEquals("1",    j.hget(pfx + "b", "DirtyBit"),     "b DirtyBit=1 after acquire");
      assertEquals("1",    j.hget(pfx + "b", "ReadAttempts"), "b ReadAttempts=1 after acquire");
      assertEquals("1000", j.hget(pfx + "b", "ReadDateTime"), "b ReadDateTime=now after acquire");

      // ack removes b (member + hash); ZCARD drops from 3 to 2; retry is NOOP.
      long before = j.zcard(q);
      Object ackout = Pq.fcall(j, "pq_ack", List.of(q, pfx + "b"), member(2, "b"), "1");
      assertEquals("OK", Pq.deep(ackout), "ack b returns OK");
      assertEquals("NOTFOUND", Pq.deep(Pq.fcallRo(j, "pq_read", List.of(pfx + "b"))), "b hash deleted");
      assertEquals(before - 1, j.zcard(q), "queue cardinality drops by 1");
      assertEquals("NOOP", Pq.deep(Pq.fcall(j, "pq_ack", List.of(q, pfx + "b"), member(2, "b"), "1")),
          "re-ack b is idempotent NOOP");

      // nack releases a; DirtyBit back to 0, ReadDateTime/ReadAttempts retained.
      Object nackout = Pq.fcall(j, "pq_nack", List.of(pfx + "a"), "1");
      assertEquals("OK", Pq.deep(nackout), "nack a returns OK");
      assertEquals("0",    j.hget(pfx + "a", "DirtyBit"),     "a DirtyBit=0 after nack");
      assertEquals("1",    j.hget(pfx + "a", "ReadAttempts"), "a ReadAttempts retained (1)");
      assertEquals("1000", j.hget(pfx + "a", "ReadDateTime"), "a ReadDateTime retained (1000)");

      // a is available again and redelivered with a higher ReadAttempts.
      Object d5 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "2000", "30000");
      assertTrue(Pq.deep(d5).contains("task-a"), "a redelivered after nack");
      assertEquals("2",    j.hget(pfx + "a", "ReadAttempts"), "a ReadAttempts incremented to 2");
      assertEquals("2000", j.hget(pfx + "a", "ReadDateTime"), "a ReadDateTime updated to 2000");
    }
  }
}
