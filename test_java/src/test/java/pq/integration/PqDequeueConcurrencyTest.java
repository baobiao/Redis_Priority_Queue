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
 * Mirrors test_bash/integration/test_pq_dequeue_concurrency.sh: concurrent consumers never
 * receive the same message. The "concurrency" is a sequence of FCALLs simulating two
 * consumers: a leased (un-expired) message is skipped, so two acquires return distinct
 * messages. Spec: FR-003, SC-003.
 */
class PqDequeueConcurrencyTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void concurrentConsumersDistinctMessages(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{n1}";
      String pfx = "pq:{n1}:m:";
      j.del(q, pfx + "m1", pfx + "m2");

      // Single available message: first acquire gets it, second finds nothing (leased).
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "m1"), "m1", "1", "Priority", "5", "Payload", "p1");
      Object d1 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d1).contains("p1"), "consumer 1 gets the only message");
      Object d2 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertEquals("", Pq.deep(d2), "consumer 2 gets null (message leased, not expired)");

      // Add a second message: consumer 2 now gets the new one, not the leased m1.
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "m2"), "m2", "2", "Priority", "5", "Payload", "p2");
      Object d3 = Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000");
      assertTrue(Pq.deep(d3).contains("p2"), "consumer 2 gets the distinct second message");
      assertFalse(Pq.deep(d3).contains("p1"),
          "second consumer must not re-receive the leased message");
    }
  }
}
