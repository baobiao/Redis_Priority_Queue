package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_pq_nack_contract.sh: KEYS[1]=message Hash, ARGV[1]=token,
 * optional ARGV[2]=VisibleAt (Feature 005). Idempotent NOOP for an absent message; EKEYS on
 * wrong key count; EARGS on a non-integer token; EFENCED on a stale token; EVIS on an invalid
 * VisibleAt (fail-before-write); OK sets VisibleAt; ENOTLEASED once released; write-flag
 * rejected under FCALL_RO.
 */
class PqNackContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void nack(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{nc}";
      String m1 = "pq:{nc}:m:1";
      String pfx = "pq:{nc}:m:";
      j.del(q, m1);

      // Absent message -> idempotent NOOP.
      assertEquals("NOOP", Pq.deep(Pq.fcall(j, "pq_nack", List.of(m1), "1")),
          "absent message -> NOOP");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_nack", List.of(q, m1), "1"));

      // Non-integer token -> EARGS.
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_nack", List.of(m1), "notanum"));

      Pq.fcall(j, "pq_enqueue", List.of(q, m1), "1", "1", "Priority", "5", "Payload", "w");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx), "1000", "30000"); // lease: token=1, DirtyBit=1

      // Stale token -> EFENCED.
      Pq.assertError("EFENCED", () -> Pq.fcall(j, "pq_nack", List.of(m1), "999"));

      // Optional VisibleAt: invalid -> EVIS (fail-before-write).
      Pq.assertError("EVIS", () -> Pq.fcall(j, "pq_nack", List.of(m1), "1", "-1"));

      // Valid nack with VisibleAt -> OK, sets VisibleAt.
      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_nack", List.of(m1), "1", "4000")),
          "nack with VisibleAt -> OK");
      assertEquals("4000", j.hget(m1, "VisibleAt"), "VisibleAt set");

      // Not in-flight now (released) -> ENOTLEASED on a second settle.
      Pq.assertError("ENOTLEASED", () -> Pq.fcall(j, "pq_nack", List.of(m1), "1"));

      // Write function: rejected under FCALL_RO.
      Pq.assertRejectedRo(j, "pq_nack", List.of(m1), "1");
    }
  }
}
