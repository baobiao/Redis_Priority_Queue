package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.List;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_peek_validation.sh: pq_peek input validation and
 * read-only malformed handling. Invalid now/timeout/count and a non-zset queue ->
 * structured errors; a malformed message Hash errors in single mode but is skipped
 * in top-N mode; nothing is ever written (peek is no-writes).
 *
 * <p>The tag-mismatch scenario uses cross-slot keys and is standalone-only (the
 * cluster client rejects them before the function's ETAG guard runs).
 */
class PqPeekValidationTest {
  private static final String Q = "pq:{pv}";
  private static final String PFX = "pq:{pv}:m:";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void peekInputAndMalformedValidation(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del(Q, PFX + "a");
      Pq.fcall(j, "pq_enqueue", List.of(Q, PFX + "a"), "a", "1", "Priority", "5", "Payload", "hi");

      // now / timeout / count validation.
      for (String bad : List.of("-1", "1.5", "abc")) {
        Pq.assertError("ENOW", () -> Pq.fcallRo(j, "pq_peek", List.of(Q, PFX), bad, "30000"));
      }
      for (String bad : List.of("0", "-5", "x")) {
        Pq.assertError("ETMO", () -> Pq.fcallRo(j, "pq_peek", List.of(Q, PFX), "1000", bad));
      }
      for (String bad : List.of("0", "-2", "1.5", "nope")) {
        Pq.assertError("ECOUNT", () -> Pq.fcallRo(j, "pq_peek", List.of(Q, PFX), "1000", "30000", bad));
      }

      // Non-zset queue key.
      j.del("str:{pv}");
      j.set("str:{pv}", "not-a-zset");
      Pq.assertError("EMALFORMED",
          () -> Pq.fcallRo(j, "pq_peek", List.of("str:{pv}", "str:{pv}:m:"), "1000", "30000"));

      // Malformed message Hash: single mode -> EMALFORMED; top-N -> skipped.
      String mq = "pq:{pvm}";
      String mpfx = "pq:{pvm}:m:";
      j.del(mq, mpfx + "bad");
      Pq.fcall(j, "pq_enqueue", List.of(mq, mpfx + "bad"), "bad", "1", "Priority", "5", "Payload", "x");
      j.del(mpfx + "bad");
      j.set(mpfx + "bad", "corrupt"); // member present, Hash is a string
      Pq.assertError("EMALFORMED", () -> Pq.fcallRo(j, "pq_peek", List.of(mq, mpfx), "1000", "30000"));
      Object topn = Pq.fcallRo(j, "pq_peek", List.of(mq, mpfx), "1000", "30000", "5");
      assertFalse(Pq.deep(topn).contains("member"),
          "top-N skips the malformed member (no error record)");

      // No writes happened anywhere: the read-only queue member is still present.
      assertEquals(Double.valueOf(5.0), j.zscore(Q, String.format("%020d:%s", 1, "a")),
          "peek wrote nothing (member intact)");
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
          () -> Pq.fcallRo(j, "pq_peek", List.of("pq:{pv}", "pq:{nope}:m:"), "1000", "30000"));
    }
  }
}
