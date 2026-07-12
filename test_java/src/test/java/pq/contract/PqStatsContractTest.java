package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;
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
 * Mirrors test_bash/contract/test_pq_stats_contract.sh: KEYS = queue, prefix, [DLQ]; ARGV =
 * now, timeout, [max_scan]. Returns a cheap flat map (depth/dlq_depth/front_priority). It is
 * no-writes: callable via both FCALL_RO and FCALL, and leaves the message unleased. 2-key and
 * 3-key forms are valid. Errors: EKEYS/ENOW/ETMO/ESCAN/ETAG/EMALFORMED.
 *
 * <p>The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster
 * those keys span slots, so the cross-slot call is rejected before the Lua runs.
 */
class PqStatsContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void stats(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      String q = "pq:{sc}";
      String pfx = "pq:{sc}:m:";
      String h1 = "pq:{sc}:m:1";
      String dl = "dlq:{sc}";
      j.del(q, dl, h1);
      Pq.fcall(j, "pq_enqueue", List.of(q, h1), "1", "1", "Priority", "5", "Payload", "x");

      // Cheap tier via FCALL_RO (no-writes): returns depth/dlq_depth/front_priority.
      String cheap = Pq.deep(Pq.fcallRo(j, "pq_stats", List.of(q, pfx, dl), "1000", "30000"));
      assertTrue(cheap.contains("depth"), "cheap map has depth");
      assertTrue(cheap.contains("dlq_depth"), "cheap map has dlq_depth");
      assertTrue(cheap.contains("front_priority"), "cheap map has front_priority");

      // 2-key form (no DLQ) is valid.
      assertTrue(Pq.deep(Pq.fcallRo(j, "pq_stats", List.of(q, pfx), "1000", "30000")).contains("depth"),
          "2-key form valid");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcallRo(j, "pq_stats", List.of(q), "1000", "30000"));
      Pq.assertError("EKEYS", () -> Pq.fcallRo(j, "pq_stats",
          List.of(q, pfx, dl, "x:{sc}"), "1000", "30000"));

      // Bad args.
      Pq.assertError("ENOW", () -> Pq.fcallRo(j, "pq_stats", List.of(q, pfx), "-1", "30000"));
      Pq.assertError("ETMO", () -> Pq.fcallRo(j, "pq_stats", List.of(q, pfx), "1000", "0"));
      Pq.assertError("ESCAN", () -> Pq.fcallRo(j, "pq_stats", List.of(q, pfx), "1000", "30000", "-1"));

      // Tag mismatch -> ETAG (standalone) / cross-slot rejection (cluster).
      if (combo.topology() == Engines.Topology.CLUSTER) {
        assertThrows(JedisException.class,
            () -> Pq.fcallRo(j, "pq_stats", List.of("pq:{sc}", "pq:{other}:m:"), "1000", "30000"));
      } else {
        Pq.assertError("ETAG",
            () -> Pq.fcallRo(j, "pq_stats", List.of("pq:{sc}", "pq:{other}:m:"), "1000", "30000"));
      }

      // Non-zset queue -> EMALFORMED.
      j.del("str:{sc}");
      j.set("str:{sc}", "notazset");
      Pq.assertError("EMALFORMED",
          () -> Pq.fcallRo(j, "pq_stats", List.of("str:{sc}", "str:{sc}:m:"), "1000", "30000"));

      // It is no-writes: FCALL (write path) also works, and it left the message unleased.
      assertTrue(Pq.deep(Pq.fcall(j, "pq_stats", List.of(q, pfx), "1000", "30000")).contains("depth"),
          "stats callable via FCALL too");
      assertEquals("0", j.hget(h1, "DirtyBit"), "stats wrote nothing (message unleased)");
    }
  }
}
