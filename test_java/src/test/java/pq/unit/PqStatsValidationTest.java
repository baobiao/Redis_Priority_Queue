package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_stats_validation.sh: pq_stats validation
 * (read-only). Invalid now/timeout/max_scan and a non-zset queue return the
 * correct PQ E... errors; stats never writes (the seeded message stays unleased).
 *
 * <p>The tag-mismatch scenario uses cross-slot keys and is standalone-only.
 */
class PqStatsValidationTest {
  private static final String Q = "pq:{sv}";
  private static final String PFX = "pq:{sv}:m:";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void statsValidation(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del(Q, PFX + "1");
      Pq.fcall(j, "pq_enqueue", List.of(Q, PFX + "1"), "1", "1", "Priority", "5", "Payload", "x");

      for (String bad : List.of("-1", "1.5", "abc")) {
        Pq.assertError("ENOW", () -> Pq.fcallRo(j, "pq_stats", List.of(Q, PFX), bad, "30000"));
      }
      for (String bad : List.of("0", "-5", "abc")) {
        Pq.assertError("ETMO", () -> Pq.fcallRo(j, "pq_stats", List.of(Q, PFX), "1000", bad));
      }
      for (String bad : List.of("-1", "1.5", "abc")) {
        Pq.assertError("ESCAN", () -> Pq.fcallRo(j, "pq_stats", List.of(Q, PFX), "1000", "30000", bad));
      }

      // Non-zset queue.
      j.del("str:{sv}");
      j.set("str:{sv}", "notazset");
      Pq.assertError("EMALFORMED",
          () -> Pq.fcallRo(j, "pq_stats", List.of("str:{sv}", "str:{sv}:m:"), "1000", "30000"));

      // Read-only: the seeded message is unchanged (never leased) after all calls.
      assertEquals("0", j.hget(PFX + "1", "DirtyBit"), "stats wrote nothing (DirtyBit still 0)");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void tagMismatch(Engines.Combo combo) {
    Assumptions.assumeTrue(combo.topology() == Engines.Topology.STANDALONE,
        "cross-slot ETAG check is standalone-only");
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      Pq.assertError("ETAG",
          () -> Pq.fcallRo(j, "pq_stats", List.of("pq:{sv}", "pq:{nope}:m:"), "1000", "30000"));
    }
  }
}
