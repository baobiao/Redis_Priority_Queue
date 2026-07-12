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
 * Mirrors test_bash/unit/test_pq_dequeue_validation.sh: input/precondition
 * rejection for dequeue/ack/nack and the fail-before-write guarantee.
 *
 * <p>The Bash suite runs this standalone only (ETAG is enforced by the function
 * itself). The prefix-tag-mismatch scenario uses cross-slot keys, which the
 * cluster client rejects before the function runs, so it is standalone-only here;
 * every other scenario runs on all reachable combos (same-slot / single-key).
 */
class PqDequeueValidationTest {
  private static final String Q = "pq:{u1}";
  private static final String PFX = "pq:{u1}:m:";

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void dequeueAckNackValidation(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del(Q, PFX + "y", PFX + "z");

      // ----- pq_dequeue input validation -----
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_dequeue", List.of(Q), "1000", "30000"));
      Pq.assertError("ENOW", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "-1", "30000"));
      Pq.assertError("ENOW", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "abc", "30000"));
      Pq.assertError("ETMO", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "0"));
      Pq.assertError("ETMO", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "1.5"));
      Pq.assertError("ESCAN", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "30000", "-1"));

      // Non-sorted-set queue -> EMALFORMED (fail-before-write).
      j.del(Q);
      j.set(Q, "notazset");
      Pq.assertError("EMALFORMED", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "30000"));
      j.del(Q);

      // ----- Set up one enqueued (available) message y for settle checks -----
      Pq.fcall(j, "pq_enqueue", List.of(Q, PFX + "y"), "y", "1", "Priority", "5", "Payload", "py");
      String ymember = String.format("%020d:%s", 1, "y");

      // ack/nack on a not-in-flight message -> ENOTLEASED (nothing changes).
      Pq.assertError("ENOTLEASED", () -> Pq.fcall(j, "pq_ack", List.of(Q, PFX + "y"), ymember, "1"));
      Pq.assertError("ENOTLEASED", () -> Pq.fcall(j, "pq_nack", List.of(PFX + "y"), "1"));

      // ack/nack arg validation.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_ack", List.of(Q), ymember, "1"));
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_ack", List.of(Q, PFX + "y"), "", "1"));
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_nack", List.of(PFX + "y", Q), "1"));
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_nack", List.of(PFX + "y"), "abc"));

      // Lease y, then a wrong token is fenced.
      Pq.fcall(j, "pq_dequeue", List.of(Q, PFX), "1000", "30000");
      Pq.assertError("EFENCED", () -> Pq.fcall(j, "pq_ack", List.of(Q, PFX + "y"), ymember, "999"));
      Pq.assertError("EFENCED", () -> Pq.fcall(j, "pq_nack", List.of(PFX + "y"), "999"));

      // Settling an absent message -> idempotent NOOP.
      assertEquals("NOOP", Pq.deep(Pq.fcall(j, "pq_ack", List.of(Q, PFX + "absent"),
          String.format("%020d:%s", 9, "absent"), "1")), "ack absent -> NOOP");
      assertEquals("NOOP", Pq.deep(Pq.fcall(j, "pq_nack", List.of(PFX + "absent"), "1")),
          "nack absent -> NOOP");

      // Fail-before-write: y is still leased and unchanged, queue still holds 1 member.
      assertEquals("1", j.hget(PFX + "y", "DirtyBit"), "y still in-flight (DirtyBit=1)");
      assertEquals("1", j.hget(PFX + "y", "ReadAttempts"), "y ReadAttempts unchanged (1)");
      assertEquals(1L, j.zcard(Q), "queue still has 1 member");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void prefixTagMismatch(Engines.Combo combo) {
    // Cross-slot keys are rejected by the cluster client (JedisClusterOperationException)
    // before the function's ETAG guard can run, so this check is standalone-only.
    Assumptions.assumeTrue(combo.topology() == Engines.Topology.STANDALONE,
        "cross-slot ETAG check is standalone-only");
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      Pq.assertError("ETAG", () -> Pq.fcall(j, "pq_dequeue", List.of(Q, "pq:{u2}:m:"), "1000", "30000"));
    }
  }
}
