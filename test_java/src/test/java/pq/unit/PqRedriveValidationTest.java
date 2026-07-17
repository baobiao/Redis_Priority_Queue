package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.util.List;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_redrive_validation.sh: pq_redrive input
 * validation + fail-before-write. Bad key count / empty member, and a dangling or
 * malformed message Hash -> the correct PQ E... results; nothing is written on any
 * failure.
 *
 * <p>The tag-mismatch scenario uses cross-slot keys and is standalone-only.
 */
class PqRedriveValidationTest {
  private static final String Q = "pq:{uv}";
  private static final String PFX = "pq:{uv}:m:";
  private static final String DL = "dlq:{uv}";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void redriveValidation(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del(Q, DL, PFX + "X", PFX + "Y");

      // Bad key count.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_redrive", List.of(DL, Q), "m"));
      // Empty member.
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_redrive", List.of(DL, Q, PFX + "X"), ""));

      // Dangling DLQ member: present in the DLQ but its message Hash is missing.
      String mX = String.format("%020d:%s", 1, "X");
      j.zadd(DL, 5, mX);
      Pq.assertError("EMALFORMED", () -> Pq.fcall(j, "pq_redrive", List.of(DL, Q, PFX + "X"), mX));
      assertEquals(Double.valueOf(5.0), j.zscore(DL, mX), "no write: X still in the DLQ");
      assertNull(j.zscore(Q, mX), "no write: X not added to the source");

      // Malformed message Hash: member in DLQ, Hash key holds a non-hash value.
      String mY = String.format("%020d:%s", 2, "Y");
      j.zadd(DL, 5, mY);
      j.set(PFX + "Y", "corrupt");
      Pq.assertError("EMALFORMED", () -> Pq.fcall(j, "pq_redrive", List.of(DL, Q, PFX + "Y"), mY));
      assertEquals(Double.valueOf(5.0), j.zscore(DL, mY), "no write: Y still in the DLQ");
      assertNull(j.zscore(Q, mY), "no write: Y not added to the source");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void tagMismatch(Engines.Combo combo) {
    Assumptions.assumeTrue(combo.topology() == Engines.Topology.STANDALONE,
        "cross-slot ETAG check is standalone-only");
    try (UnifiedJedis j = Pq.connect(combo)) {
      Pq.assertError("ETAG", () -> Pq.fcall(j, "pq_redrive",
          List.of("dlq:{uv}", "pq:{nope}", "pq:{uv}:m:X"), "anything"));
    }
  }
}
