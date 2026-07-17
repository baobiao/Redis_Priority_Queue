package pq.support;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.function.Executable;
import redis.clients.jedis.UnifiedJedis;
import redis.clients.jedis.exceptions.JedisDataException;
import redis.clients.jedis.resps.LibraryInfo;

/**
 * Thin helpers mirroring the Bash harness (load_and_call.sh) for the parity suites:
 * load the library, FCALL / FCALL_RO, decode flat replies, and assert {@code PQ …}
 * error replies. The library name and function names live in the Lua source, so every
 * client drives the identical library.
 */
public final class Pq {
  private Pq() {}

  public static final String LIBRARY = "priority_queue";
  public static final String RO_ON_WRITE =
      "Can not execute a script with write flag using *_ro command";

  private static volatile String source;

  public static String source() {
    if (source == null) source = Repo.read("src/functions/priority_queue.lua");
    return source;
  }

  /** FUNCTION LOAD REPLACE; returns the registered library name (expected "priority_queue"). */
  public static String load(UnifiedJedis j) {
    return j.functionLoadReplace(source());
  }

  /** Connect a client for this combo and FUNCTION LOAD the library (mirrors the Bash
   *  load_library step); use in a try-with-resources so the client is closed. */
  public static UnifiedJedis connect(Engines.Combo combo) {
    UnifiedJedis j = combo.connect();
    load(j);
    return j;
  }

  public static Object fcall(UnifiedJedis j, String fn, List<String> keys, List<String> args) {
    return j.fcall(fn, keys, args);
  }

  public static Object fcallRo(UnifiedJedis j, String fn, List<String> keys, List<String> args) {
    return j.fcallReadonly(fn, keys, args);
  }

  // Varargs conveniences ---------------------------------------------------

  public static Object fcall(UnifiedJedis j, String fn, List<String> keys, String... args) {
    return j.fcall(fn, keys, List.of(args));
  }

  public static Object fcallRo(UnifiedJedis j, String fn, List<String> keys, String... args) {
    return j.fcallReadonly(fn, keys, List.of(args));
  }

  // Reply decoding ---------------------------------------------------------

  /** Recursively flatten a reply to a searchable string (mirrors the Bash text dump). */
  public static String deep(Object o) {
    if (o == null) return "";
    if (o instanceof byte[] b) return new String(b, StandardCharsets.UTF_8);
    if (o instanceof List<?> list) {
      StringBuilder sb = new StringBuilder();
      for (Object x : list) sb.append(deep(x)).append(' ');
      return sb.toString().trim();
    }
    return String.valueOf(o);
  }

  /** Flat [k, v, k, v, …] reply → ordered map (values stringified via {@link #deep}). */
  public static Map<String, String> pairs(Object reply) {
    Map<String, String> m = new LinkedHashMap<>();
    if (reply instanceof List<?> l) {
      for (int i = 0; i + 1 < l.size(); i += 2) m.put(deep(l.get(i)), deep(l.get(i + 1)));
    }
    return m;
  }

  // FUNCTION LIST helpers --------------------------------------------------

  public static List<String> libraryNames(UnifiedJedis j) {
    List<String> names = new ArrayList<>();
    for (LibraryInfo li : j.functionList()) names.add(li.getLibraryName());
    return names;
  }

  /** True if any registered function advertises the {@code no-writes} flag. */
  public static boolean anyNoWritesFlag(UnifiedJedis j) {
    for (LibraryInfo li : j.functionListWithCode()) {
      if (String.valueOf(li.getFunctions()).contains("no-writes")) return true;
    }
    return false;
  }

  // Error assertions -------------------------------------------------------

  /** Assert the body raises a JedisDataException whose message contains {@code needle}. */
  public static void assertError(String needle, Executable body) {
    JedisDataException ex = assertThrows(JedisDataException.class, body);
    assertTrue(ex.getMessage() != null && ex.getMessage().contains(needle),
        () -> "expected error containing [" + needle + "] but got [" + ex.getMessage() + "]");
  }

  /** Assert a write function is rejected under FCALL_RO. */
  public static void assertRejectedRo(UnifiedJedis j, String fn, List<String> keys, String... args) {
    assertError(RO_ON_WRITE, () -> j.fcallReadonly(fn, keys, List.of(args)));
  }
}
