package pq.contract;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/contract/test_pq_read_contract.sh: pq_read is FCALL_RO-callable and
 * returns the field map; NOTFOUND for an absent key; EMALFORMED for a wrong-type key or a
 * message missing an original field. Feature 005 adds VisibleAt (sixth field) and Feature
 * 006 adds DeadLetteredAt (seventh field); legacy messages missing only those read as 0.
 */
class PqReadContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void read(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      // Different hash tags -> different slots, so delete individually (cluster-safe).
      j.del("q:{r1}");
      j.del("q:{absent}");
      j.del("q:{wrong}");
      Pq.fcall(j, "pq_create", List.of("q:{r1}"), "Payload", "hi", "Priority", "9");

      // read is callable via FCALL_RO (no-writes flag).
      String r1 = Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{r1}")));
      assertTrue(r1.contains("hi"), "read returns Payload");
      assertTrue(r1.contains("9"), "read returns Priority");
      assertTrue(r1.contains("ReadAttempts"), "read returns field names");

      // absent key -> NOTFOUND
      assertEquals("NOTFOUND", Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{absent}"))),
          "absent key -> NOTFOUND");

      // wrong type (string at key) -> EMALFORMED
      j.set("q:{wrong}", "notahash");
      Pq.assertError("EMALFORMED", () -> Pq.fcallRo(j, "pq_read", List.of("q:{wrong}")));

      // --- Feature 005: VisibleAt is the sixth returned field ---
      j.del("q:{rv}");
      Pq.fcall(j, "pq_create", List.of("q:{rv}"), "Priority", "5", "VisibleAt", "4242");
      String rv = Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{rv}")));
      assertTrue(rv.contains("VisibleAt"), "read returns VisibleAt label");
      assertTrue(rv.contains("4242"), "read returns VisibleAt value");

      // Message missing ONLY VisibleAt (stored before Feature 005) reads as VisibleAt=0.
      j.del("q:{rlegacy}");
      j.hset("q:{rlegacy}", Map.of("ReadAttempts", "0", "DirtyBit", "0",
          "ReadDateTime", "0", "Priority", "5", "Payload", "old"));
      String rlegacy = Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{rlegacy}")));
      assertTrue(rlegacy.contains("old"), "legacy 5-field message still reads (Payload)");
      assertTrue(rlegacy.contains("VisibleAt"), "legacy message reports VisibleAt");

      // Missing an ORIGINAL field still -> EMALFORMED (only VisibleAt is tolerated).
      j.del("q:{rbad}");
      j.hset("q:{rbad}", Map.of("ReadAttempts", "0", "DirtyBit", "0",
          "ReadDateTime", "0", "Priority", "5")); // no Payload
      Pq.assertError("EMALFORMED", () -> Pq.fcallRo(j, "pq_read", List.of("q:{rbad}")));

      // --- Feature 006: DeadLetteredAt is the seventh returned field ---
      j.del("q:{rdla}");
      Pq.fcall(j, "pq_create", List.of("q:{rdla}"), "Priority", "5", "DeadLetteredAt", "7777");
      String rdla = Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{rdla}")));
      assertTrue(rdla.contains("DeadLetteredAt"), "read returns DeadLetteredAt label");
      assertTrue(rdla.contains("7777"), "read returns DeadLetteredAt value");

      // Message missing only VisibleAt AND DeadLetteredAt (pre-005/006) reads as 0/0.
      j.del("q:{rlegacy6}");
      j.hset("q:{rlegacy6}", Map.of("ReadAttempts", "0", "DirtyBit", "0",
          "ReadDateTime", "0", "Priority", "5", "Payload", "old2"));
      String rlegacy6 = Pq.deep(Pq.fcallRo(j, "pq_read", List.of("q:{rlegacy6}")));
      assertTrue(rlegacy6.contains("old2"), "legacy message still reads (Payload)");
      assertTrue(rlegacy6.contains("DeadLetteredAt"), "legacy message reports DeadLetteredAt");
    }
  }
}
