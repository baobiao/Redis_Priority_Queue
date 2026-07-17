package pq.integration;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import pq.support.Engines;
import pq.support.Pq;
import redis.clients.jedis.UnifiedJedis;

/**
 * Mirrors test_bash/integration/test_pq_create_roundtrip.sh: create-with-defaults,
 * create-with-explicit-values, and partial create, each verified by direct Hash
 * inspection (HGET). Spec: FR-002..FR-008, SC-001/SC-002.
 */
class PqCreateRoundtripTest {

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void defaults(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{d1}");
      Pq.fcall(j, "pq_create", List.of("q:{d1}"));
      assertEquals("0",    j.hget("q:{d1}", "ReadAttempts"), "default ReadAttempts");
      assertEquals("0",    j.hget("q:{d1}", "DirtyBit"),     "default DirtyBit");
      assertEquals("0",    j.hget("q:{d1}", "ReadDateTime"), "default ReadDateTime");
      assertEquals("1000", j.hget("q:{d1}", "Priority"),     "default Priority");
      assertEquals("",     j.hget("q:{d1}", "Payload"),      "default Payload");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void explicitValues(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{v1}");
      // Explicit values incl. large epoch-ms and DirtyBit token 'true'.
      Pq.fcall(j, "pq_create", List.of("q:{v1}"),
          "ReadAttempts", "3", "DirtyBit", "true", "ReadDateTime", "1700000000000",
          "Priority", "5", "Payload", "order-42");
      assertEquals("3",             j.hget("q:{v1}", "ReadAttempts"), "explicit ReadAttempts");
      assertEquals("1",             j.hget("q:{v1}", "DirtyBit"),     "explicit DirtyBit(true->1)");
      assertEquals("1700000000000", j.hget("q:{v1}", "ReadDateTime"), "explicit ReadDateTime");
      assertEquals("5",             j.hget("q:{v1}", "Priority"),     "explicit Priority");
      assertEquals("order-42",      j.hget("q:{v1}", "Payload"),      "explicit Payload");
    }
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("pq.support.Engines#all")
  void partial(Engines.Combo combo) {
    try (UnifiedJedis j = Pq.connect(combo)) {
      j.del("q:{p1}");
      // Only Payload + Priority supplied; the rest default.
      Pq.fcall(j, "pq_create", List.of("q:{p1}"), "Payload", "x", "Priority", "7");
      assertEquals("x", j.hget("q:{p1}", "Payload"),      "partial Payload");
      assertEquals("7", j.hget("q:{p1}", "Priority"),     "partial Priority");
      assertEquals("0", j.hget("q:{p1}", "ReadAttempts"), "partial default ReadAttempts");
    }
  }
}
