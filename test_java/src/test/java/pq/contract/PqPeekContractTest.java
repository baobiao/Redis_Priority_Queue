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
 * Mirrors test_bash/contract/test_pq_peek_contract.sh: single vs top-N return, no-writes
 * (callable via FCALL_RO, leaves the message unleased at DirtyBit=0), and the
 * EKEYS/ENOW/ETMO/ECOUNT/ETAG errors. Feature 005: records carry VisibleAt; single mode
 * skips a not-yet-visible message and returns it once visible.
 *
 * <p>The ETAG case uses mismatched hash tags. On standalone the Lua guard fires; on cluster
 * those keys span slots, so the cross-slot call is rejected before the Lua runs.
 */
class PqPeekContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void peek(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{pc}";
      String mk = "pq:{pc}:m:k";
      String pfx = "pq:{pc}:m:";
      j.del(q, mk);

      // Empty queue: single -> null.
      assertEquals("", Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "30000")),
          "empty single peek -> null");

      // Enqueue one, then peek (read-only) returns a record carrying id/member/Payload.
      Pq.fcall(j, "pq_enqueue", List.of(q, mk), "k", "1", "Payload", "hello", "Priority", "5");
      String rec = Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "30000"));
      assertTrue(rec.contains("k"), "single record carries id");
      assertTrue(rec.contains(String.format("%020d:%s", 1, "k")), "single record carries member");
      assertTrue(rec.contains("hello"), "single record carries Payload");
      assertTrue(rec.contains("DirtyBit"), "single record carries DirtyBit label");

      // Top-N form is callable and returns the member.
      assertTrue(Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "30000", "2"))
          .contains("hello"), "top-N returns the member");

      // Peek is no-writes: it did not lease the message (still available at DirtyBit=0).
      assertEquals("0", j.hget(mk, "DirtyBit"), "peek left the message unleased");

      // Error surface.
      Pq.assertError("EKEYS", () -> Pq.fcallRo(j, "pq_peek", List.of(q), "1000", "30000"));
      Pq.assertError("ENOW", () -> Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "-1", "30000"));
      Pq.assertError("ETMO", () -> Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "0"));
      Pq.assertError("ECOUNT", () -> Pq.fcallRo(j, "pq_peek", List.of(q, pfx), "1000", "30000", "0"));
      if (combo.topology() == Engines.Topology.CLUSTER) {
        assertThrows(JedisException.class,
            () -> Pq.fcallRo(j, "pq_peek", List.of("pq:{pc}", "pq:{other}:m:"), "1000", "30000"));
      } else {
        Pq.assertError("ETAG",
            () -> Pq.fcallRo(j, "pq_peek", List.of("pq:{pc}", "pq:{other}:m:"), "1000", "30000"));
      }

      // --- Feature 005: records carry VisibleAt; single mode honours it ---
      String vq = "pq:{pcv}";
      String vh = "pq:{pcv}:m:h";
      String vpfx = "pq:{pcv}:m:";
      j.del(vq, vh);
      Pq.fcall(j, "pq_enqueue", List.of(vq, vh),
          "h", "1", "Priority", "5", "Payload", "hid", "VisibleAt", "9000");
      // top-N reports the record with its VisibleAt
      String topn = Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(vq, vpfx), "1000", "30000", "5"));
      assertTrue(topn.contains("VisibleAt"), "top-N record carries VisibleAt label");
      assertTrue(topn.contains("9000"), "top-N record carries VisibleAt value");
      // single mode skips it while hidden, returns it once visible
      assertEquals("", Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(vq, vpfx), "8999", "30000")),
          "single peek skips not-yet-visible -> null");
      assertTrue(Pq.deep(Pq.fcallRo(j, "pq_peek", List.of(vq, vpfx), "9000", "30000")).contains("hid"),
          "single peek returns it once visible");
    }
  }
}
