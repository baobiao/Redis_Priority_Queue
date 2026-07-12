package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_nack_visibleat_validation.sh: nack's optional
 * VisibleAt argument (ARGV[2]) validation. An invalid value (non-integer /
 * negative / &gt;2^53) is rejected with PQ EVIS and writes nothing
 * (fail-before-write); a valid one is applied.
 *
 * <p>9007199254740994 = 2^53+2 is the next integer representable as a double above
 * MAX_SAFE_INT (2^53+1 is not representable and rounds down to 2^53, which is in
 * range) - kept verbatim to probe the IEEE-754 boundary.
 */
class PqNackVisibleAtValidationTest {
  private static final String Q = "pq:{nv}";
  private static final String PFX = "pq:{nv}:m:";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void nackVisibleAtValidation(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del(Q, PFX + "1");
      Pq.fcall(j, "pq_enqueue", List.of(Q, PFX + "1"), "1", "1", "Priority", "5", "Payload", "w");
      Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "30000"); // lease (token=1, DirtyBit=1)

      // Invalid VisibleAt at nack -> EVIS, and the lease is untouched.
      for (String bad : List.of("-1", "1.5", "abc", "9007199254740994")) {
        Pq.assertError("EVIS", () -> Pq.fcall(j, "pq_nack", List.of(PFX + "1"), "1", bad));
      }
      assertEquals("1", j.hget(PFX + "1", "DirtyBit"),
          "no write on EVIS: still in-flight (DirtyBit=1)");
      assertEquals("0", j.hget(PFX + "1", "VisibleAt"),
          "no write on EVIS: VisibleAt unchanged (0)");

      // A valid VisibleAt is applied (released + hidden).
      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_nack", List.of(PFX + "1"), "1", "7000")),
          "valid nack-with-delay returns OK");
      assertEquals("0", j.hget(PFX + "1", "DirtyBit"), "DirtyBit cleared to 0");
      assertEquals("7000", j.hget(PFX + "1", "VisibleAt"), "VisibleAt applied (7000)");
    }
  }
}
