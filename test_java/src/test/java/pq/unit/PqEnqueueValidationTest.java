package pq.unit;

import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_enqueue_validation.sh: pq_enqueue input
 * rejection and the no-write guarantee (neither the message Hash nor the queue
 * index is created on any failure).
 */
class PqEnqueueValidationTest {
  private static final String Q = "pq:{u1}";
  private static final String M = "pq:{u1}:m:x";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void enqueueValidation(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del(Q, M);

      Pq.assertError("EID", () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "", "1"));
      Pq.assertError("ESEQ", () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "-1"));
      Pq.assertError("ESEQ", () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "1.5"));
      Pq.assertError("ESEQ", () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "abc"));
      Pq.assertError("EINVAL: Priority",
          () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "1", "Priority", "foo"));
      Pq.assertError("EFIELD: Color",
          () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "1", "Color", "red"));
      Pq.assertError("EDUP: Priority",
          () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "1", "Priority", "1", "Priority", "2"));
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_enqueue", List.of(Q, M), "x", "1", "Payload"));

      // Nothing written to either structure after any failure.
      assertFalse(j.exists(M), "no message hash stored");
      assertFalse(j.exists(Q), "queue index not created");
    }
  }
}
