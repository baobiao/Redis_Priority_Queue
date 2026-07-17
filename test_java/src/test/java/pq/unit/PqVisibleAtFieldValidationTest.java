package pq.unit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_visibleat_field_validation.sh: the VisibleAt
 * field validated through validate/create/enqueue. A valid VisibleAt is accepted;
 * a non-integer / negative / &gt;2^53 value is rejected with PQ EINVAL: VisibleAt,
 * writing nothing.
 *
 * <p>MAX = 9007199254740992 (2^53) is accepted; 9007199254740994 (2^53+2, the next
 * integer representable as a double above MAX_SAFE_INT) is rejected - kept verbatim.
 */
class PqVisibleAtFieldValidationTest {
  private static final String MAX = "9007199254740992"; // 2^53

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void visibleAtFieldValidation(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {

      // Valid values accepted (validate is no-writes; create stores).
      for (String v : List.of("0", "1", "1000", MAX)) {
        assertEquals("VALID", Pq.deep(Pq.fcallRo(j, "pq_validate", List.of(), "VisibleAt", v)),
            "validate accepts VisibleAt=" + v);
      }

      // Invalid values rejected with EINVAL: VisibleAt.
      for (String bad : List.of("-1", "1.5", "abc", "9007199254740994")) {
        Pq.assertError("EINVAL: VisibleAt", () -> Pq.fcallRo(j, "pq_validate", List.of(), "VisibleAt", bad));
      }

      // create rejects a bad VisibleAt and writes nothing.
      j.del("q:{vf}:m:1");
      Pq.assertError("EINVAL: VisibleAt",
          () -> Pq.fcall(j, "pq_create", List.of("q:{vf}:m:1"), "Priority", "5", "VisibleAt", "-5"));
      assertFalse(j.exists("q:{vf}:m:1"), "nothing written on create failure");

      // enqueue rejects a bad VisibleAt and writes neither the Hash nor the queue member.
      j.del("pq:{vf}", "pq:{vf}:m:1");
      Pq.assertError("EINVAL: VisibleAt",
          () -> Pq.fcall(j, "pq_enqueue", List.of("pq:{vf}", "pq:{vf}:m:1"),
              "1", "1", "Priority", "5", "VisibleAt", "notanum"));
      assertFalse(j.exists("pq:{vf}:m:1"), "no message Hash written");
      assertEquals(0L, j.zcard("pq:{vf}"), "no queue member written");

      // A valid VisibleAt is stored and read back.
      j.del("q:{vf}:m:2");
      Pq.fcall(j, "pq_create", List.of("q:{vf}:m:2"), "Priority", "5", "VisibleAt", "12345");
      assertEquals("12345", j.hget("q:{vf}:m:2", "VisibleAt"), "valid VisibleAt stored");
    }
  }
}
