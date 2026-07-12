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
 * Mirrors test_bash/contract/test_pq_dequeue_contract.sh: KEYS/ARGV shape, handle vs null
 * reply, EKEYS on wrong key count, and the write-flag (rejected under FCALL_RO). Feature 004
 * adds the optional KEYS[3]=DLQ + trailing cap ARGV with ECAP/ETAG/EMALFORMED.
 *
 * <p>The ETAG case uses mismatched hash tags on purpose. On standalone the Lua guard fires
 * (PQ ETAG). On cluster those keys span slots, so the client/server reject the cross-slot
 * call before the Lua runs -- the single-slot enforcement is the equivalent protection.
 */
class PqDequeueContractTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void dequeue(Engines.Combo combo) {
    try (UnifiedJedis j = combo.connect()) {
      Pq.load(j);
      j.del("pq:{c1}", "pq:{c1}:m:x");

      // Empty queue -> null reply (empty output).
      assertEquals("", Pq.deep(Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:"), "1000", "30000")), "empty queue returns null");

      // Enqueue one, then acquire -> the handle carries id/member/ReadAttempts/Payload.
      Pq.fcall(j, "pq_enqueue", List.of("pq:{c1}", "pq:{c1}:m:x"),
          "x", "1", "Payload", "hello", "Priority", "5");
      String handle = Pq.deep(Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:"), "1000", "30000"));
      assertTrue(handle.contains("x"), "handle carries id");
      assertTrue(handle.contains(String.format("%020d:%s", 1, "x")), "handle carries member");
      assertTrue(handle.contains("ReadAttempts"), "handle carries ReadAttempts label");
      assertTrue(handle.contains("hello"), "handle carries Payload value");

      // Wrong key count -> EKEYS.
      Pq.assertError("EKEYS",
          () -> Pq.fcall(j, "pq_dequeue", List.of("pq:{c1}"), "1000", "30000"));

      // Write function: must be rejected under FCALL_RO.
      Pq.assertRejectedRo(j, "pq_dequeue", List.of("pq:{c1}", "pq:{c1}:m:"), "1000", "30000");

      // --- Feature 004 dead-letter mode: optional KEYS[3]=DLQ + trailing cap ARGV ---
      j.del("pq:{c1}", "pq:{c1}:m:x", "dlq:{c1}");
      Pq.fcall(j, "pq_enqueue", List.of("pq:{c1}", "pq:{c1}:m:x"),
          "x", "1", "Payload", "hello", "Priority", "5");

      // 3-key call with a valid cap: below-cap message is leased and returned as usual.
      assertTrue(Pq.deep(Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"), "1000", "30000", "0", "5")).contains("hello"),
          "3-key dead-letter call still returns a handle");

      // Too many keys -> EKEYS.
      Pq.assertError("EKEYS", () -> Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{c1}", "x:{c1}"), "1000", "30000"));

      // Dead-letter mode with a missing/invalid cap -> ECAP.
      Pq.assertError("ECAP", () -> Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"), "1000", "30000"));
      Pq.assertError("ECAP", () -> Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"), "1000", "30000", "0", "0"));

      // DLQ key not sharing the source hash tag -> ETAG (standalone) / cross-slot (cluster).
      if (combo.topology() == Engines.Topology.CLUSTER) {
        assertThrows(JedisException.class, () -> Pq.fcall(j, "pq_dequeue",
            List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{other}"), "1000", "30000", "0", "5"));
      } else {
        Pq.assertError("ETAG", () -> Pq.fcall(j, "pq_dequeue",
            List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{other}"), "1000", "30000", "0", "5"));
      }

      // DLQ key holding a non-sorted-set value -> EMALFORMED.
      j.del("dlq:{c1}");
      j.set("dlq:{c1}", "not-a-zset");
      Pq.assertError("EMALFORMED", () -> Pq.fcall(j, "pq_dequeue",
          List.of("pq:{c1}", "pq:{c1}:m:", "dlq:{c1}"), "1000", "30000", "0", "5"));
      j.del("dlq:{c1}");
    }
  }
}
