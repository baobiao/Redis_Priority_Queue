package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_redrive.sh: redrive a message from the DLQ
 * back to the source. The member moves DLQ -> source at score=Priority (verbatim),
 * delivery state resets (ReadAttempts=0, DirtyBit=0) while ReadDateTime is retained,
 * and it is redelivered on the next dequeue; a member not in the DLQ is a NOOP; a
 * member already in the source is rejected (EQDUP) with no duplicate.
 */
class PqRedriveTest {

  // ---- Dead-letter G (cap=1), redrive it, redeliver, then NOOP on a non-DLQ member ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void redriveResetsAndRedelivers(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q = "pq:{rd}", pfx = "pq:{rd}:m:", dl = "dlq:{rd}";
      j.del(q, dl, pfx + "G");
      Pq.fcall(j, "pq_enqueue", List.of(q, pfx + "G"), "G", "1", "Priority", "5", "Payload", "PAY-G");
      String mG = String.format("%020d:%s", 1, "G");
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "1000", "30000", "0", "1"); // RA 0<1 -> leased, RA=1, RDT=1000
      Pq.fcall(j, "pq_nack", List.of(pfx + "G"), "1");                           // RA=1, DirtyBit=0
      Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "2000", "30000", "0", "1"); // RA=1>=1 -> dead-lettered
      assertEquals(5.0, (double) j.zscore(dl, mG), "G is in the DLQ before redrive");

      Object out = Pq.fcall(j, "pq_redrive", List.of(dl, q, pfx + "G"), mG);
      assertEquals("OK", Pq.deep(out), "redrive returns OK");
      assertEquals(5.0, (double) j.zscore(q, mG), "G back in the source at score=Priority");
      assertNull(j.zscore(dl, mG), "G removed from the DLQ");
      assertEquals("0", j.hget(pfx + "G", "ReadAttempts"), "redrive reset ReadAttempts=0");
      assertEquals("0", j.hget(pfx + "G", "DirtyBit"), "redrive reset DirtyBit=0");
      assertEquals("1000", j.hget(pfx + "G", "ReadDateTime"), "redrive retained ReadDateTime (1000)");

      // Redelivered on the next dequeue (below the cap after reset).
      out = Pq.fcall(j, "pq_dequeue", List.of(q, pfx, dl), "5000", "30000", "0", "1");
      assertTrue(Pq.deep(out).contains("PAY-G"), "redriven G is delivered again");

      // ---- NOOP when the member is not in the DLQ ----
      out = Pq.fcall(j, "pq_redrive", List.of(dl, q, pfx + "G"), mG);
      assertEquals("NOOP", Pq.deep(out), "redrive of a non-DLQ member -> NOOP");
    }
  }

  // ---- Reject (no duplicate) when the member is already in the source ----
  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void rejectAlreadyInSource(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      String q2 = "pq:{rd2}", pfx2 = "pq:{rd2}:m:", dl2 = "dlq:{rd2}";
      j.del(q2, dl2, pfx2 + "H");
      Pq.fcall(j, "pq_enqueue", List.of(q2, pfx2 + "H"), "H", "1", "Priority", "5", "Payload", "PAY-H");
      String mH = String.format("%020d:%s", 1, "H");
      j.zadd(dl2, 5, mH); // H present in BOTH source and DLQ
      Pq.assertError("EQDUP", () -> Pq.fcall(j, "pq_redrive", List.of(dl2, q2, pfx2 + "H"), mH));
      assertEquals(5.0, (double) j.zscore(q2, mH), "source still holds H (unchanged)");
      assertEquals(5.0, (double) j.zscore(dl2, mH), "DLQ copy of H untouched by the rejected redrive");
    }
  }
}
