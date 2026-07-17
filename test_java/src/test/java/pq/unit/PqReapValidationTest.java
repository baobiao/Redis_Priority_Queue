package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_reap_validation.sh: pq_reap validation +
 * fail-before-write. Invalid now/retention/limit and a tag mismatch return the
 * correct PQ E... errors and write nothing (a seeded expired entry survives).
 *
 * <p>The tag-mismatch scenario uses cross-slot keys and is standalone-only.
 */
class PqReapValidationTest {
  private static final String DL = "dlq:{rv}";
  private static final String PFX = "pq:{rv}:m:";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void reapValidation(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del(DL, PFX + "1");
      // Seed one clearly-expired entry; assert it survives every rejected call.
      Pq.fcall(j, "pq_create", List.of(PFX + "1"), "Priority", "5", "Payload", "x", "DeadLetteredAt", "1");
      String m1 = String.format("%020d:%s", 1, "1");
      j.zadd(DL, 5, m1);

      for (String bad : List.of("-1", "1.5", "abc")) {
        Pq.assertError("ENOW", () -> Pq.fcall(j, "pq_reap", List.of(DL, PFX), bad, "1000", "10"));
      }
      for (String bad : List.of("-1", "1.5", "abc")) {
        Pq.assertError("ERET", () -> Pq.fcall(j, "pq_reap", List.of(DL, PFX), "100000", bad, "10"));
      }
      for (String bad : List.of("0", "-5", "1.5", "abc")) {
        Pq.assertError("ELIMIT", () -> Pq.fcall(j, "pq_reap", List.of(DL, PFX), "100000", "1000", bad));
      }

      // Nothing was written on any failure: the expired entry is still present.
      assertEquals(Double.valueOf(5.0), j.zscore(DL, m1), "no write on failure: member intact");
      assertTrue(j.exists(PFX + "1"), "no write on failure: hash intact");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void tagMismatch(Engines.Combo combo) {
    Assumptions.assumeTrue(combo.topology() == Engines.Topology.STANDALONE,
        "cross-slot ETAG check is standalone-only");
    try (UnifiedJedis j = Pq.connect(combo)) {
      Pq.assertError("ETAG",
          () -> Pq.fcall(j, "pq_reap", List.of("dlq:{rv}", "pq:{nope}:m:"), "100000", "1000", "10"));
    }
  }
}
