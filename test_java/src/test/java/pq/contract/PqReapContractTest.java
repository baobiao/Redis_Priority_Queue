package pq.contract;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;
import redis.clients.jedis.exceptions.JedisException;

/**
 * Mirrors test_bash/contract/test_pq_reap_contract.sh: KEYS[1]=DLQ, KEYS[2]=prefix; ARGV =
 * now, retention, limit; returns a {removed,scanned,truncated} map. An expired entry removes
 * both the member and its Hash. Write-flag rejected under FCALL_RO. Errors:
 * EKEYS/ENOW/ERET/ELIMIT/ETAG/EMALFORMED.
 *
 * <p>The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster
 * those keys span slots, so the cross-slot call is rejected before the Lua runs.
 */
class PqReapContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void reap(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String dl = "dlq:{rc}";
      String pfx = "pq:{rc}:m:";
      String h1 = "pq:{rc}:m:1";
      j.del(dl, h1);

      // Empty DLQ -> zero map.
      String empty = Pq.deep(Pq.fcall(j, "pq_reap", List.of(dl, pfx), "1000", "1000", "10"));
      assertTrue(empty.contains("removed"), "empty DLQ reports removed");
      assertTrue(empty.contains("scanned"), "empty DLQ reports scanned");
      assertTrue(empty.contains("truncated"), "empty DLQ reports truncated");

      // One expired entry -> removed (member + Hash).
      Pq.fcall(j, "pq_create", List.of(h1), "Priority", "5", "Payload", "x", "DeadLetteredAt", "100");
      String member = String.format("%020d:%s", 1, "1");
      j.zadd(dl, 5, member);
      String reaped = Pq.deep(Pq.fcall(j, "pq_reap", List.of(dl, pfx), "100000", "1000", "10"));
      assertTrue(reaped.contains("removed"), "expired entry removed");
      assertNull(j.zscore(dl, member), "member gone");
      assertFalse(j.exists(h1), "hash deleted");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_reap", List.of(dl), "1000", "1000", "10"));

      // Invalid args.
      Pq.assertError("ENOW", () -> Pq.fcall(j, "pq_reap", List.of(dl, pfx), "-1", "1000", "10"));
      Pq.assertError("ERET", () -> Pq.fcall(j, "pq_reap", List.of(dl, pfx), "1000", "-1", "10"));
      Pq.assertError("ELIMIT", () -> Pq.fcall(j, "pq_reap", List.of(dl, pfx), "1000", "1000", "0"));

      // Tag mismatch -> ETAG (standalone) / cross-slot rejection (cluster).
      if (combo.topology() == Engines.Topology.CLUSTER) {
        assertThrows(JedisException.class,
            () -> Pq.fcall(j, "pq_reap", List.of("dlq:{rc}", "pq:{other}:m:"), "1000", "1000", "10"));
      } else {
        Pq.assertError("ETAG",
            () -> Pq.fcall(j, "pq_reap", List.of("dlq:{rc}", "pq:{other}:m:"), "1000", "1000", "10"));
      }

      // Non-zset DLQ -> EMALFORMED.
      j.del("str:{rc}");
      j.set("str:{rc}", "notazset");
      Pq.assertError("EMALFORMED",
          () -> Pq.fcall(j, "pq_reap", List.of("str:{rc}", "str:{rc}:m:"), "1000", "1000", "10"));

      // Write function: rejected under FCALL_RO.
      Pq.assertRejectedRo(j, "pq_reap", List.of(dl, pfx), "1000", "1000", "10");
    }
  }
}
