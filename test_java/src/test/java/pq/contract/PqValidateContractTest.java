package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_pq_validate_contract.sh: pq_validate takes no KEYS
 * (numkeys 0), is FCALL_RO-callable, returns VALID for valid/empty input, and reports
 * EINVAL (out-of-range value) / EFIELD (unknown field) with the offending field name.
 */
class PqValidateContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void validate(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);

      assertEquals("VALID", Pq.deep(Pq.fcallRo(j, "pq_validate", List.of(),
          "Priority", "5", "DirtyBit", "true")), "valid input -> VALID");
      assertEquals("VALID", Pq.deep(Pq.fcallRo(j, "pq_validate", List.of())),
          "empty (all defaults) -> VALID");

      Pq.assertError("EINVAL: ReadAttempts",
          () -> Pq.fcallRo(j, "pq_validate", List.of(), "ReadAttempts", "-1"));
      Pq.assertError("EFIELD: Nope",
          () -> Pq.fcallRo(j, "pq_validate", List.of(), "Nope", "1"));
    }
  }
}
