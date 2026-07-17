package pq.unit;

import static org.junit.jupiter.api.Assertions.assertFalse;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/unit/test_pq_validation.sh: pq_create validation rules
 * (invalid values, unknown/duplicate fields) and the guarantee that nothing is
 * stored on failure.
 */
class PqValidationTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void validationRules(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{bad}");

      Pq.assertError("EINVAL: ReadAttempts",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "ReadAttempts", "-1"));
      Pq.assertError("EINVAL: ReadAttempts",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "ReadAttempts", "1.5"));
      Pq.assertError("EINVAL: ReadAttempts",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "ReadAttempts", "abc"));
      Pq.assertError("EINVAL: DirtyBit",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "DirtyBit", "maybe"));
      Pq.assertError("EINVAL: ReadDateTime",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "ReadDateTime", "-7"));
      Pq.assertError("EINVAL: Priority",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "Priority", "xx"));
      Pq.assertError("EFIELD: Color",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "Color", "red"));
      Pq.assertError("EDUP: Priority",
          () -> Pq.fcall(j, "pq_create", List.of("q:{bad}"), "Priority", "1", "Priority", "2"));

      // Nothing stored on any failure.
      assertFalse(j.exists("q:{bad}"), "no hash stored after failures");
    }
  }
}
