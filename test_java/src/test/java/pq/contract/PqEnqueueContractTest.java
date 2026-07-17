package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_pq_enqueue_contract.sh: pq_enqueue takes KEYS[1]=queue
 * Sorted Set, KEYS[2]=message Hash, ARGV = id, sequence, then field pairs; returns OK.
 * Wrong key count -> EKEYS. It is a write function: rejected under FCALL_RO.
 */
class PqEnqueueContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void enqueue(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("pq:{c1}", "pq:{c1}:m:1");

      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_enqueue",
          List.of("pq:{c1}", "pq:{c1}:m:1"), "1", "1", "Payload", "hello", "Priority", "5")),
          "enqueue returns OK");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_enqueue", List.of("pq:{c1}"), "1", "1"));

      // Write function: rejected under FCALL_RO.
      j.del("pq:{c3}", "pq:{c3}:m:1");
      Pq.assertRejectedRo(j, "pq_enqueue", List.of("pq:{c3}", "pq:{c3}:m:1"), "1", "1");
    }
  }
}
