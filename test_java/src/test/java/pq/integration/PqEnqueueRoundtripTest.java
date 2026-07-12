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
 * Mirrors test_bash/integration/test_pq_enqueue_roundtrip.sh: priority ordering (incl.
 * boundary values), FIFO among equal priorities, and stored-message fidelity.
 * Spec: FR-002/004/005/013/016, SC-001/SC-002/SC-003.
 */
class PqEnqueueRoundtripTest {

  /** member = fixed-width zero-padded sequence (20 digits) + ':' + id (see the Lua source). */
  private static String member(long seq, String id) {
    return String.format("%020d:%s", seq, id);
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void priorityOrderingInclBoundaries(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{o1}", "pq:{o1}:m:low", "pq:{o1}:m:mid", "pq:{o1}:m:hi",
            "pq:{o1}:m:min", "pq:{o1}:m:max");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{o1}", "pq:{o1}:m:low"), "low", "1", "Priority", "1000");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{o1}", "pq:{o1}:m:mid"), "mid", "2", "Priority", "100");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{o1}", "pq:{o1}:m:hi"),  "hi",  "3", "Priority", "5");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{o1}", "pq:{o1}:m:min"), "min", "4", "Priority", "-9007199254740992");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{o1}", "pq:{o1}:m:max"), "max", "5", "Priority", "9007199254740992");

      // Ascending by score: min(-2^53) < hi(5) < mid(100) < low(1000) < max(2^53).
      List<String> expected = List.of(
          member(4, "min"), member(3, "hi"), member(2, "mid"), member(1, "low"), member(5, "max"));
      assertEquals(expected, j.zrange("pq:{o1}", 0, -1),
          "priority order (incl. boundaries) ascending by score");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void fifoWithinEqualPriority(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{f1}", "pq:{f1}:m:a", "pq:{f1}:m:b", "pq:{f1}:m:c");
      // Enqueued out of order (b, a, c) but with sequences 11, 10, 12 at equal Priority.
      Pq.fcall(j, "pq_enqueue", List.of("pq:{f1}", "pq:{f1}:m:b"), "b", "11", "Priority", "50");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{f1}", "pq:{f1}:m:a"), "a", "10", "Priority", "50");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{f1}", "pq:{f1}:m:c"), "c", "12", "Priority", "50");
      List<String> expected = List.of(member(10, "a"), member(11, "b"), member(12, "c"));
      assertEquals(expected, j.zrange("pq:{f1}", 0, -1), "FIFO by sequence within equal priority");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void storedMessageFidelity(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{r1}", "pq:{r1}:m:1");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{r1}", "pq:{r1}:m:1"),
          "1", "1", "Payload", "order-42", "Priority", "5");
      Object msg = Pq.fcallRo(j, "pq_read", List.of("pq:{r1}:m:1"));
      assertTrue(Pq.deep(msg).contains("order-42"), "stored Payload readable");
      assertEquals(5.0, j.zscore("pq:{r1}", member(1, "1")).doubleValue(), "score equals Priority");
      assertEquals("0", j.hget("pq:{r1}:m:1", "ReadAttempts"), "omitted ReadAttempts defaulted");
      assertEquals("0", j.hget("pq:{r1}:m:1", "DirtyBit"),     "omitted DirtyBit defaulted");
      assertEquals("5", j.hget("pq:{r1}:m:1", "Priority"),     "stored Priority field");
    }
  }
}
