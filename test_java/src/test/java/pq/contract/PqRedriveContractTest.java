package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;
import redis.clients.jedis.exceptions.JedisException;

/**
 * Mirrors test_bash/contract/test_pq_redrive_contract.sh: KEYS = DLQ, source, message Hash;
 * ARGV = member. OK on a move (member re-scored into the source), NOOP when absent from the
 * DLQ. Write-flag rejected under FCALL_RO. Errors: EKEYS/EARGS/ETAG.
 *
 * <p>The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster
 * those keys span slots, so the cross-slot call is rejected before the Lua runs.
 */
class PqRedriveContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void redrive(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{rc}";
      String dl = "dlq:{rc}";
      String msgKey = "pq:{rc}:m:k";
      j.del(q, dl, msgKey);

      // Place k in the DLQ with its Hash at the normal source-prefixed key.
      Pq.fcall(j, "pq_enqueue", List.of(q, msgKey), "k", "1", "Priority", "5", "Payload", "hello");
      String member = String.format("%020d:%s", 1, "k");
      j.zrem(q, member);
      j.zadd(dl, 5, member);

      // Move it back -> OK; then a second redrive is a NOOP (no longer in the DLQ).
      assertEquals("OK", Pq.deep(Pq.fcall(j, "pq_redrive", List.of(dl, q, msgKey), member)),
          "redrive returns OK");
      assertEquals(Double.valueOf(5.0), j.zscore(q, member), "k moved back to the source");
      assertEquals("NOOP", Pq.deep(Pq.fcall(j, "pq_redrive", List.of(dl, q, msgKey), member)),
          "redrive of an absent DLQ member -> NOOP");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_redrive", List.of(dl, q), member));

      // Empty member -> EARGS.
      Pq.assertError("EARGS", () -> Pq.fcall(j, "pq_redrive", List.of(dl, q, msgKey), ""));

      // Tag mismatch across the three keys -> ETAG (standalone) / cross-slot (cluster).
      if (combo.topology() == Engines.Topology.CLUSTER) {
        assertThrows(JedisException.class, () -> Pq.fcall(j, "pq_redrive",
            List.of("dlq:{rc}", "pq:{other}", "pq:{rc}:m:k"), member));
      } else {
        Pq.assertError("ETAG", () -> Pq.fcall(j, "pq_redrive",
            List.of("dlq:{rc}", "pq:{other}", "pq:{rc}:m:k"), member));
      }

      // Write function: must be rejected under FCALL_RO.
      Pq.assertRejectedRo(j, "pq_redrive", List.of(dl, q, msgKey), member);
    }
  }
}
