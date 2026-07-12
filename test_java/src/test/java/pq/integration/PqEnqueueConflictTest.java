package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_enqueue_conflict.sh: occupied message location
 * (EEXISTS), wrong-type queue key (EMALFORMED), already-enqueued member (EQDUP), and the
 * atomic no-write-on-failure guarantee. Spec: FR-009/FR-010/FR-011/FR-012, SC-004/SC-006.
 */
class PqEnqueueConflictTest {

  private static String member(long seq, String id) {
    return String.format("%020d:%s", seq, id);
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void occupiedMessageLocationEExists(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{x1}", "pq:{x1}:m:1");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{x1}", "pq:{x1}:m:1"), "1", "1", "Priority", "5");
      long before = j.zcard("pq:{x1}");
      Pq.assertError("EEXISTS",
          () -> Pq.fcall(j, "pq_enqueue", List.of("pq:{x1}", "pq:{x1}:m:1"), "1", "2", "Priority", "9"));
      assertEquals(before, j.zcard("pq:{x1}"), "queue cardinality unchanged after EEXISTS");
      assertEquals(5.0, j.zscore("pq:{x1}", member(1, "1")).doubleValue(),
          "original score unchanged after EEXISTS");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void wrongTypeQueueEMalformed(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{x2}", "pq:{x2}:m:1");
      j.set("pq:{x2}", "notazset");
      Pq.assertError("EMALFORMED",
          () -> Pq.fcall(j, "pq_enqueue", List.of("pq:{x2}", "pq:{x2}:m:1"), "1", "1", "Priority", "5"));
      assertFalse(j.exists("pq:{x2}:m:1"), "message hash not created on wrong-type queue");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void alreadyEnqueuedMemberEQDup(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{x3}", "pq:{x3}:m:1", "pq:{x3}:m:2");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{x3}", "pq:{x3}:m:1"), "dup", "7", "Priority", "5");
      long before = j.zcard("pq:{x3}");
      // Same id+sequence -> same member -> EQDUP, even via a different message key.
      Pq.assertError("EQDUP",
          () -> Pq.fcall(j, "pq_enqueue", List.of("pq:{x3}", "pq:{x3}:m:2"), "dup", "7", "Priority", "9"));
      assertEquals(before, j.zcard("pq:{x3}"), "queue cardinality unchanged after EQDUP");
      assertFalse(j.exists("pq:{x3}:m:2"), "second message hash not created after EQDUP");
    }
  }
}
