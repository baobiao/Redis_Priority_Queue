package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_function_flags.sh: pq_read/pq_validate/pq_peek carry
 * the no-writes flag (FCALL_RO-callable) while writers are rejected under FCALL_RO.
 */
class FunctionFlagsTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void flags(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      assertEquals(Pq.LIBRARY, Pq.load(j), "library registered as priority_queue");
      assertTrue(Pq.libraryNames(j).contains(Pq.LIBRARY), "library listed");
      assertTrue(Pq.anyNoWritesFlag(j), "no-writes flag present");

      // Writers must be rejected under FCALL_RO (no no-writes flag).
      Pq.assertRejectedRo(j, "pq_create", List.of("q:{flag}"));
      Pq.assertRejectedRo(j, "pq_enqueue", List.of("pq:{flag}", "pq:{flag}:m:1"), "1", "1");
      Pq.assertRejectedRo(j, "pq_dequeue", List.of("pq:{flag}", "pq:{flag}:m:"), "1000", "30000");
      Pq.assertRejectedRo(j, "pq_ack", List.of("pq:{flag}", "pq:{flag}:m:1"), "00000000000000000001:1", "1");
      Pq.assertRejectedRo(j, "pq_nack", List.of("pq:{flag}:m:1"), "1");
      Pq.assertRejectedRo(j, "pq_redrive",
          List.of("dlq:{flag}", "pq:{flag}", "pq:{flag}:m:1"), "00000000000000000001:1");

      // pq_peek is no-writes and IS callable via FCALL_RO (empty -> null).
      j.del("pq:{flag}");
      Object peek = Pq.fcallRo(j, "pq_peek", List.of("pq:{flag}", "pq:{flag}:m:"), "1000", "30000");
      assertEquals("", Pq.deep(peek), "peek callable via FCALL_RO (empty -> null)");

      // Reader works under the read-only command.
      j.del("q:{flag}");
      Pq.fcall(j, "pq_create", List.of("q:{flag}"));
      Object read = Pq.fcallRo(j, "pq_read", List.of("q:{flag}"));
      assertTrue(Pq.deep(read).contains("Priority"), "read works via FCALL_RO");
    }
  }
}
