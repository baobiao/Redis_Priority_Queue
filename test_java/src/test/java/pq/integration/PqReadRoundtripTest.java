package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_read_roundtrip.sh: create->read type fidelity
 * (DirtyBit false round-trips to integer 0, large epoch preserved, negative Priority
 * preserved) and read-does-not-mutate. Spec: FR-009/FR-010/FR-014/FR-015, SC-003.
 */
class PqReadRoundtripTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void roundTripPreservesTypesAndReadDoesNotMutate(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);

      // DirtyBit=false round-trips to integer 0 (not nil); large epoch preserved.
      j.del("q:{rt}");
      Pq.fcall(j, "pq_create", List.of("q:{rt}"),
          "DirtyBit", "false", "ReadDateTime", "1700000000000", "Priority", "-5");

      Object out = Pq.fcallRo(j, "pq_read", List.of("q:{rt}"));
      assertTrue(Pq.deep(out).contains("DirtyBit"),      "read shows DirtyBit field");
      assertTrue(Pq.deep(out).contains("1700000000000"), "read preserves epoch ms");
      assertTrue(Pq.deep(out).contains("-5"),            "read preserves negative Priority");

      // read does not mutate the stored hash (Map equality is order-independent,
      // mirroring the Bash `HGETALL | sort` comparison).
      Map<String, String> before = j.hgetAll("q:{rt}");
      Pq.fcallRo(j, "pq_read", List.of("q:{rt}"));
      Map<String, String> after = j.hgetAll("q:{rt}");
      assertEquals(before, after, "read does not mutate");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void dirtyBitTrueStoredAsOne(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("q:{rt2}");
      Pq.fcall(j, "pq_create", List.of("q:{rt2}"), "DirtyBit", "1");
      assertEquals("1", j.hget("q:{rt2}", "DirtyBit"), "DirtyBit true stored as 1");
    }
  }
}
