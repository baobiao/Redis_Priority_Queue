package pq.support;

import java.io.InputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.stream.Stream;

import org.junit.jupiter.params.provider.Arguments;
import redis.clients.jedis.HostAndPort;
import redis.clients.jedis.JedisCluster;
import redis.clients.jedis.JedisPooled;
import redis.clients.jedis.UnifiedJedis;

/**
 * Engine × topology matrix for the parity suite, sourced from the repo-root
 * {@code engines.env} (env vars override the file). Mirrors the Bash harness'
 * ENGINES loop (redis + valkey) and adds the automated cluster topology that the
 * Bash suite covers only as a manual smoke.
 *
 * <p>Only reachable combos are yielded, so a developer who has not run
 * {@code docker_engines.sh cluster-up} still gets the standalone combos. The
 * verification run brings both standalone and cluster up, so all four run.
 */
public final class Engines {
  private Engines() {}

  public enum Topology { STANDALONE, CLUSTER }

  public record Combo(String engine, Topology topology, String host, int port) {
    public String label() { return engine + "-" + topology.name().toLowerCase(); }

    /** A fresh client for this combo (JedisPooled standalone, JedisCluster cluster). */
    public UnifiedJedis connect() {
      if (topology == Topology.CLUSTER) {
        return new JedisCluster(new HostAndPort(host, port));
      }
      return new JedisPooled(host, port);
    }

    @Override public String toString() { return label(); }
  }

  private static final String HOST = "127.0.0.1";

  /** Every reachable (engine, topology) combo. */
  public static List<Combo> combos() {
    Properties p = env();
    List<Combo> all = List.of(
        new Combo("redis",  Topology.STANDALONE, HOST, port(p, "REDIS_PORT",          7379)),
        new Combo("valkey", Topology.STANDALONE, HOST, port(p, "VALKEY_PORT",         7380)),
        new Combo("redis",  Topology.CLUSTER,    HOST, port(p, "REDIS_CLUSTER_PORT",  7381)),
        new Combo("valkey", Topology.CLUSTER,    HOST, port(p, "VALKEY_CLUSTER_PORT", 7382)));
    List<Combo> reachable = new ArrayList<>();
    for (Combo c : all) {
      if (reachable(c)) reachable.add(c);
    }
    if (reachable.isEmpty()) {
      throw new IllegalStateException(
          "No engines reachable on 127.0.0.1. Run: test_bash/harness/docker_engines.sh up (and cluster-up).");
    }
    return reachable;
  }

  /** JUnit @MethodSource provider: one argument (the Combo) per reachable combo. */
  public static Stream<Arguments> all() {
    return combos().stream().map(Arguments::of);
  }

  private static boolean reachable(Combo c) {
    try (Socket s = new Socket()) {
      s.connect(new InetSocketAddress(c.host(), c.port()), 600);
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  private static int port(Properties p, String key, int dflt) {
    String env = System.getenv(key);
    if (env != null && !env.isBlank()) return Integer.parseInt(env.trim());
    String v = p.getProperty(key);
    return (v == null || v.isBlank()) ? dflt : Integer.parseInt(v.trim());
  }

  /** Load engines.env by walking up from the working directory to the repo root. */
  private static Properties env() {
    Properties props = new Properties();
    Path f = Repo.find("engines.env");
    if (f != null) {
      try (InputStream in = Files.newInputStream(f)) {
        props.load(in);
      } catch (Exception ignored) {
        // fall back to env vars / defaults
      }
    }
    return props;
  }
}
