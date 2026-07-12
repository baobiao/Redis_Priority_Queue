package pq.support;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/** Locate repo files by walking up from the working directory (mvn runs in test_java/). */
public final class Repo {
  private Repo() {}

  public static Path find(String relative) {
    Path dir = Paths.get("").toAbsolutePath();
    for (int i = 0; i < 12 && dir != null; i++, dir = dir.getParent()) {
      Path candidate = dir.resolve(relative);
      if (Files.exists(candidate)) return candidate;
    }
    return null;
  }

  public static String read(String relative) {
    Path p = find(relative);
    if (p == null) throw new IllegalStateException("repo file not found: " + relative);
    try {
      return Files.readString(p);
    } catch (Exception e) {
      throw new RuntimeException("failed reading " + p, e);
    }
  }
}
