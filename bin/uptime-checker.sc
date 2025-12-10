#!/usr/bin/env scala-cli

//> using scala 3.7
//> using dep com.softwaremill.sttp.client3::core:3.11.0

import sttp.client3.*
import java.time.{Duration, Instant, LocalTime}
import java.time.format.DateTimeFormatter
import scala.util.{Try, Success, Failure}

case class DowntimePeriod(start: Instant, var duration: Option[Duration] = None)

case class Stats(
  var total: Long = 0,
  var success: Long = 0,
  var failure: Long = 0,
  startTime: Instant = Instant.now(),
  var lastFailureTime: Option[Instant] = None,
  var downtimePeriods: List[DowntimePeriod] = Nil
)

val url = args.headOption.getOrElse("https://idempotent.io/_internal_/healthcheck")
val intervalMs = args.drop(1).headOption.flatMap(s => Try(s.toInt).toOption).getOrElse(250)

val stats = Stats()
var inDowntime = false
var downtimeStart: Option[Instant] = None
val backend = HttpClientSyncBackend()
val timeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss.SSS")

def formatDuration(d: Duration): String =
  val millis = d.toMillis
  if millis < 1000 then s"${millis}ms"
  else if millis < 60000 then f"${millis / 1000.0}%.2fs"
  else
    val minutes = millis / 60000
    val secs = (millis % 60000) / 1000.0
    f"${minutes}m ${secs}%.1fs"

def formatDurationOpt(d: Option[Duration]): String =
  d.map(formatDuration).getOrElse("ongoing")

def now(): String = LocalTime.now().format(timeFormatter)

def printStats(): Unit =
  val elapsed = Duration.between(stats.startTime, Instant.now())
  val successRate = if stats.total > 0 then (stats.success.toDouble / stats.total * 100) else 0.0
  val totalDowntime = stats.downtimePeriods.flatMap(_.duration).foldLeft(Duration.ZERO)(_.plus(_))

  println()
  println()
  println("----------- Statistics -----------")
  println(s"        Duration: ${formatDuration(elapsed)}")
  println(s"  Total requests: ${stats.total}")
  println(f"       Successes: ${stats.success} ($successRate%.2f%%)")
  println(f"        Failures: ${stats.failure} (${100 - successRate}%.2f%%)")
  println(s"Downtime periods: ${stats.downtimePeriods.length}")
  println(s"  Total downtime: ${formatDuration(totalDowntime)}")
  println()

  if stats.downtimePeriods.nonEmpty then
    println()
    println("Downtime events:")
    stats.downtimePeriods.zipWithIndex.foreach { case (period, i) =>
      val startTime = LocalTime.ofInstant(period.start, java.time.ZoneId.systemDefault()).format(timeFormatter)
      println(s"  ${i + 1}. $startTime - ${formatDurationOpt(period.duration)}")
    }

Runtime.getRuntime.addShutdownHook(new Thread(() => {
  if inDowntime then
    downtimeStart.foreach { start =>
      stats.downtimePeriods.lastOption.foreach(_.duration = Some(Duration.between(start, Instant.now())))
    }
  printStats()
}))

println("Uptime Checker")
println("==============")
println(s"URL: $url")
println(s"Interval: ${intervalMs}ms")
println("Press Ctrl+C to stop and see statistics")
println()

while true do
  stats.total += 1

  val result = Try {
    val request = basicRequest
      .get(uri"$url")
      .readTimeout(scala.concurrent.duration.Duration(2, "seconds"))
    request.send(backend)
  }

  result match
    case Success(response) if response.code.isSuccess =>
      stats.success += 1
      if inDowntime then
        val duration = downtimeStart.map(s => Duration.between(s, Instant.now()))
        stats.downtimePeriods.lastOption.foreach(_.duration = duration)
        println(s"${now()} ✓ RECOVERED after ${formatDurationOpt(duration)}")
        inDowntime = false
        downtimeStart = None
      else
        print(s"\r${now()} ✓ ${response.code.code} | Total: ${stats.total} | Success: ${stats.success} | Fail: ${stats.failure}    ")

    case Success(response) =>
      stats.failure += 1
      stats.lastFailureTime = Some(Instant.now())
      if !inDowntime then
        inDowntime = true
        downtimeStart = Some(Instant.now())
        stats.downtimePeriods = stats.downtimePeriods :+ DowntimePeriod(Instant.now())
        println(s"\n${now()} ✗ DOWN - HTTP ${response.code.code}")
      else
        val elapsed = downtimeStart.map(s => formatDuration(Duration.between(s, Instant.now()))).getOrElse("")
        print(s"\r${now()} ✗ DOWN - HTTP ${response.code.code} ($elapsed)    ")

    case Failure(e) =>
      stats.failure += 1
      stats.lastFailureTime = Some(Instant.now())
      val errorMsg = Option(e.getMessage).map(m => if m.length > 50 then m.take(47) + "..." else m).getOrElse("Unknown error")
      if !inDowntime then
        inDowntime = true
        downtimeStart = Some(Instant.now())
        stats.downtimePeriods = stats.downtimePeriods :+ DowntimePeriod(Instant.now())
        println(s"\n${now()} ✗ DOWN - $errorMsg")
      else
        val elapsed = downtimeStart.map(s => formatDuration(Duration.between(s, Instant.now()))).getOrElse("")
        print(s"\r${now()} ✗ DOWN - $errorMsg ($elapsed)    ")

  System.out.flush()
  Thread.sleep(intervalMs)
