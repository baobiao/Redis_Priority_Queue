package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_pq_create_contract.sh: pq_create returns OK for
 * all-defaults and for supplied field pairs, and rejects odd ARGV (EARGS), unknown
 * fields (EFIELD), and duplicate fields (EDUP).
 */
class PqCreateContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void create(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{c1}");

      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_create", List.of("q:{c1}"))),
          "create all-defaults returns OK");
      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_create", List.of("q:{c1}"),
          "Payload", "hello", "Priority", "5")), "create with values returns OK");

      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_create", List.of("q:{c1}"), "Payload"));
      Pq.assertError("EFIELD", () -> Pq.fcall(j, "pq_create", List.of("q:{c1}"), "Color", "red"));
      Pq.assertError("EDUP",
          () -> Pq.fcall(j, "pq_create", List.of("q:{c1}"), "Priority", "1", "Priority", "2"));
    }
  }
}
