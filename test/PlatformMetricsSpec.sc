#!/usr/bin/env scala-cli

//> using scala 3.8
//> using dep com.typesafe:config:1.4.7
//> using dep org.json4s::json4s-native:4.0.7

import org.json4s.*
import org.json4s.native.JsonMethods.*
import java.io.{File, PrintWriter}
import java.nio.file.{Files, Paths}
import scala.sys.process.*
import scala.util.{Try, Using}

implicit val formats: Formats = DefaultFormats

// ── Test infrastructure ───────────────────────────────────────────────────────

var passed = 0
var failed = 0

def test(name: String)(body: => Unit): Unit =
  try
    body
    println(s"  PASS  $name")
    passed += 1
  catch
    case e: AssertionError =>
      println(s"  FAIL  $name")
      println(s"        ${e.getMessage}")
      failed += 1
    case e: Exception =>
      println(s"  FAIL  $name")
      println(s"        ${e.getClass.getSimpleName}: ${e.getMessage}")
      failed += 1

def assertEqual[A](actual: A, expected: A, msg: String = ""): Unit =
  if actual != expected then
    val detail = if msg.nonEmpty then s" ($msg)" else ""
    throw AssertionError(s"Expected: $expected\n        Actual:   $actual$detail")

def assertContains(haystack: String, needle: String): Unit =
  if !haystack.contains(needle) then
    throw AssertionError(s"Expected to contain: $needle\n        In: $haystack")

def assertNotContains(haystack: String, needle: String): Unit =
  if haystack.contains(needle) then
    throw AssertionError(s"Expected NOT to contain: $needle\n        In: $haystack")

// ── Script invocation helpers ─────────────────────────────────────────────────

// Resolve bin/platform-metrics.sc relative to the devops root (one level above test/)
val platformMetricsScript: String = Paths.get(System.getProperty("user.dir")).resolve("bin/platform-metrics.sc").toAbsolutePath.toString

case class RunResult(exitCode: Int, stdout: String, stderr: String)

def runScript(extraArgs: Seq[String], extraEnv: Map[String, String] = Map.empty): RunResult =
  val stdoutBuf = new StringBuilder
  val stderrBuf = new StringBuilder

  val processLogger = ProcessLogger(
    line => stdoutBuf.append(line).append("\n"),
    line => stderrBuf.append(line).append("\n")
  )

  // Start from the current system env, clear PLATFORM vars, then apply overrides.
  // This preserves PATH, HOME, JAVA_HOME etc. that scala-cli needs.
  import scala.jdk.CollectionConverters.*
  val sysEnv: Map[String, String] = System.getenv().asScala.toMap
  val cleared = sysEnv ++ Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "")
  val mergedEnv = (cleared ++ extraEnv).toSeq

  val cmd = Seq("scala-cli", "run", platformMetricsScript, "--") ++ extraArgs
  val pb = Process(cmd, None, mergedEnv*)
  val exitCode = pb.!(processLogger)

  RunResult(exitCode, stdoutBuf.toString.trim, stderrBuf.toString.trim)

/** Write HOCON content to a temp file, set PLATFORM_CONFIG_FILE to its path,
  * and call body. The file is deleted after body returns.
  */
def withTempConfig(content: String)(body: (File, Map[String, String]) => Unit): Unit =
  val tmpFile = File.createTempFile("platform-metrics-config-", ".conf")
  try
    Using(new PrintWriter(tmpFile)) { pw => pw.write(content) }
    body(tmpFile, Map("PLATFORM_CONFIG_FILE" -> tmpFile.getAbsolutePath))
  finally
    tmpFile.delete()

// ── record-point tests ────────────────────────────────────────────────────────

println("\nrecord-point")

test("builds correct POST URL and body") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "well_pump_total_gpd",
      "--date", "2026-04-27",
      "--value", "1187",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test123", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assertEqual(result.exitCode, 0)
  assertContains(result.stdout, "POST")
  assertContains(result.stdout, "/hpca/metrics/points")
  assertContains(result.stdout, "series_key")
  assertContains(result.stdout, "water")
  assertContains(result.stdout, "well_pump_total_gpd")
  assertContains(result.stdout, "2026-04-27")
  assertContains(result.stdout, "1187")
}

test("body uses 'date' field not 'point_date'") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "well_pump_total_gpd",
      "--date", "2026-04-27",
      "--value", "1187",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test123", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  val bodyLine = result.stdout.linesIterator.find(_.contains("Body:")).getOrElse("")
  assertContains(bodyLine, "\"date\"")
  assertNotContains(bodyLine, "point_date")
}

test("rejects invalid date format") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "some_key",
      "--date", "27-04-2026",
      "--value", "100",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "date")
}

test("rejects non-numeric value") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "some_key",
      "--date", "2026-04-27",
      "--value", "not-a-number",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "Invalid numeric value")
}

test("requires --tenant flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "100",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--tenant")
}

test("requires --series-key flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "100",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--series-key")
}

test("requires --metric-key flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--date", "2026-04-27",
      "--value", "100",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--metric-key")
}

test("requires --date flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--value", "100",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--date")
}

test("requires --value flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--value")
}

// ── set-metric dry-run tests ──────────────────────────────────────────────────

println("\nset-metric")

test("dry-run prints two GET lookups then PUT with body") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "well_pump_total_gpd",
      "--name", "Well Pump Total GPD",
      "--unit", "gpd",
      "--aggregation", "avg",
      "--description", "Water pumped from well",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test123", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assertEqual(result.exitCode, 0)
  // Verify the series lookup GET
  assertContains(result.stdout, "GET")
  assertContains(result.stdout, "/hpca/metrics/series")
  assertContains(result.stdout, "key=water")
  // Verify the metrics lookup GET
  assertContains(result.stdout, "/hpca/metrics/metrics")
  assertContains(result.stdout, "well_pump_total_gpd")
  // Verify the PUT
  assertContains(result.stdout, "PUT")
  assertContains(result.stdout, "/hpca/metrics/metrics")
  // Verify body fields
  assertContains(result.stdout, "Well Pump Total GPD")
  assertContains(result.stdout, "gpd")
  assertContains(result.stdout, "avg")
  assertContains(result.stdout, "Water pumped from well")
}

test("absent optional flags produce body without those keys") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "well_pump_total_gpd",
      "--name", "Well Pump",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assertEqual(result.exitCode, 0)
  val bodyLine = result.stdout.linesIterator.find(_.contains("Body:")).getOrElse("")
  assertContains(bodyLine, "\"name\"")
  assertNotContains(bodyLine, "\"unit\"")
  assertNotContains(bodyLine, "\"aggregation\"")
  assertNotContains(bodyLine, "\"description\"")
}

test("empty set-metric body is valid (no optional keys)") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "well_pump_total_gpd",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assertEqual(result.exitCode, 0)
  assertContains(result.stdout, "PUT")
}

test("set-metric requires --tenant flag") {
  val result = runScript(
    Seq(
      "set-metric",
      "--series-key", "water",
      "--metric-key", "key",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--tenant")
}

test("set-metric requires --series-key flag") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--metric-key", "key",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--series-key")
}

test("set-metric requires --metric-key flag") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--metric-key")
}

test("rejects invalid aggregation") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--aggregation", "mean",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "aggregation")
}

test("set-metric does not accept --display-order flag") {
  val result = runScript(
    Seq(
      "set-metric",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--display-order", "1",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_test", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  // --display-order is not supported; should fail as unknown flag
  assert(result.exitCode != 0)
}

// ── Config lookup precedence ──────────────────────────────────────────────────

println("\nConfig lookup precedence")

test("CLI flag --token takes precedence over env var") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "10",
      "--token", "tok_from_flag",
      "--api-url", "https://flag.example.com",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_from_env", "PLATFORM_API_URL" -> "https://env.example.com")
  )
  assertEqual(result.exitCode, 0)
  assertContains(result.stdout, "flag.example.com")
}

test("env var PLATFORM_TOKEN is used when no CLI flag") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "10",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_env123", "PLATFORM_API_URL" -> "https://env.example.com")
  )
  assertEqual(result.exitCode, 0)
}

test("config file is used when no CLI flag and no env var") {
  withTempConfig("""
    |default {
    |  api_url = "https://config.example.com"
    |  platform_token = "tok_from_config"
    |}
    """.stripMargin) { (_, configEnv) =>
    val result = runScript(
      Seq(
        "record-point",
        "--tenant", "hpca",
        "--series-key", "water",
        "--metric-key", "key",
        "--date", "2026-04-27",
        "--value", "10",
        "--dry-run"
      ),
      Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "") ++ configEnv
    )
    assertEqual(result.exitCode, 0)
    assertContains(result.stdout, "config.example.com")
  }
}

test("profile selection works with config file") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "10",
      "--profile", "staging",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok_env", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assertEqual(result.exitCode, 0)
}

test("missing token exits with non-zero code and clear message") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "10",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "token")
}

// ── Config file tests ─────────────────────────────────────────────────────────

println("\nConfig file")

test("platform_token and api_url loaded from temp config file") {
  withTempConfig("""
    |default {
    |  api_url = "https://from-file.example.com"
    |  platform_token = "tok_from_file"
    |}
    """.stripMargin) { (_, configEnv) =>
    val result = runScript(
      Seq(
        "record-point",
        "--tenant", "hpca",
        "--series-key", "water",
        "--metric-key", "key",
        "--date", "2026-04-27",
        "--value", "10",
        "--dry-run"
      ),
      Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "") ++ configEnv
    )
    assertEqual(result.exitCode, 0)
    assertContains(result.stdout, "from-file.example.com")
  }
}

test("--profile foo reads the foo block from config file") {
  withTempConfig("""
    |default {
    |  api_url = "https://default.example.com"
    |  platform_token = "tok_default"
    |}
    |staging {
    |  api_url = "https://staging.example.com"
    |  platform_token = "tok_staging"
    |}
    """.stripMargin) { (_, configEnv) =>
    val result = runScript(
      Seq(
        "record-point",
        "--tenant", "hpca",
        "--series-key", "water",
        "--metric-key", "key",
        "--date", "2026-04-27",
        "--value", "10",
        "--profile", "staging",
        "--dry-run"
      ),
      Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "") ++ configEnv
    )
    assertEqual(result.exitCode, 0)
    assertContains(result.stdout, "staging.example.com")
  }
}

test("old hoa_token key in config file is NOT recognized") {
  withTempConfig("""
    |default {
    |  api_url = "https://from-file.example.com"
    |  hoa_token = "tok_old_key"
    |}
    """.stripMargin) { (_, configEnv) =>
    val result = runScript(
      Seq(
        "record-point",
        "--tenant", "hpca",
        "--series-key", "water",
        "--metric-key", "key",
        "--date", "2026-04-27",
        "--value", "10",
        "--dry-run"
      ),
      Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "") ++ configEnv
    )
    // Should fail because hoa_token is not recognized, only platform_token is
    assert(result.exitCode != 0)
    assertContains(result.stderr, "token")
  }
}

test("malformed HOCON in config file produces clear stderr error") {
  withTempConfig("this is { not valid hocon !!!") { (_, configEnv) =>
    val result = runScript(
      Seq(
        "record-point",
        "--tenant", "hpca",
        "--series-key", "water",
        "--metric-key", "key",
        "--date", "2026-04-27",
        "--value", "10",
        "--dry-run"
      ),
      Map("PLATFORM_TOKEN" -> "", "PLATFORM_API_URL" -> "") ++ configEnv
    )
    assert(result.exitCode != 0)
    assertContains(result.stderr, "Error parsing config file")
  }
}

// ── Unknown subcommand / flags ────────────────────────────────────────────────

println("\nError handling")

test("unknown subcommand exits non-zero") {
  val result = runScript(
    Seq("unknown-cmd"),
    Map("PLATFORM_TOKEN" -> "tok", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
}

test("unknown flag exits non-zero") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value", "10",
      "--unknown-flag",
      "--dry-run"
    ),
    Map("PLATFORM_TOKEN" -> "tok", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
}

test("known flag with no value gives clear error") {
  val result = runScript(
    Seq(
      "record-point",
      "--tenant", "hpca",
      "--series-key", "water",
      "--metric-key", "key",
      "--date", "2026-04-27",
      "--value"
      // no value follows --value
    ),
    Map("PLATFORM_TOKEN" -> "tok", "PLATFORM_API_URL" -> "https://api.example.com")
  )
  assert(result.exitCode != 0)
  assertContains(result.stderr, "--value requires a value")
}

// ── Summary ───────────────────────────────────────────────────────────────────

println()
println(s"Results: $passed passed, $failed failed")
if failed > 0 then
  sys.exit(1)
