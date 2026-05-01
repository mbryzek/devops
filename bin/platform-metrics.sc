#!/usr/bin/env -S scala-cli shebang

//> using scala 3.8
//> using dep com.softwaremill.sttp.client3::core:3.11.0
//> using dep com.typesafe:config:1.4.7
//> using dep org.playframework::play-json:3.0.5
//> using dep org.playframework::play:3.0.7
//> using dep org.typelevel::cats-core:2.13.0
//> using dep joda-time:joda-time:2.13.1
//> using file ../generated/app/apibuilder/BryzekPlayModelComBryzekPlatformError.scala
//> using file ../generated/app/apibuilder/BryzekPlayModelComBryzekPlatformMetrics.scala
//> using file ../generated/app/apibuilder/GeneratedBinders.scala

import com.bryzek.platform.error.models.ValidationError
import com.bryzek.platform.error.models.json.*
import com.bryzek.platform.metrics.models.{Aggregation, MetricUnit, MetricUpsertForm, PointForm}
import com.bryzek.platform.metrics.models.json.*
import com.typesafe.config.{Config, ConfigFactory, ConfigException}
import org.joda.time.LocalDate
import play.api.libs.json.{JsError, JsPath, JsResult, JsSuccess, JsValue, Json, JsonValidationError, Reads}
import sttp.client3.*

import java.io.File
import java.nio.file.{Files, Paths}
import java.nio.file.attribute.PosixFilePermission
import java.util.Base64
import scala.util.{Try, Success, Failure}

// ── Exit codes ────────────────────────────────────────────────────────────────
val ExitOk           = 0
val ExitValidation   = 1
val ExitServerError  = 2
val ExitNetwork      = 3
val ExitMissingToken = 4

// ── Argument parsing ──────────────────────────────────────────────────────────

case class ParsedArgs(
  subcommand: String,
  tenant: Option[String]      = None,
  seriesKey: Option[String]   = None,
  metricKey: Option[String]   = None,
  date: Option[String]        = None,
  value: Option[String]       = None,
  name: Option[String]        = None,
  unit: Option[String]        = None,
  aggregation: Option[String] = None,
  description: Option[String] = None,
  file: Option[String]        = None,
  token: Option[String]       = None,
  apiUrl: Option[String]      = None,
  profile: String             = "default",
  verbose: Boolean            = false,
  dryRun: Boolean             = false
)

def parseArgs(rawArgs: Array[String]): Either[String, ParsedArgs] =
  if rawArgs.isEmpty then
    Left(usageMessage)
  else
    val subcommand = rawArgs(0)
    subcommand match
      case "record-point" | "record-points" | "set-metric" =>
        parseSubcommandArgs(subcommand, rawArgs.drop(1))
      case "help" | "--help" | "-h" =>
        Left(usageMessage)
      case unknownSubcommand =>
        Left(s"Unknown subcommand: $unknownSubcommand\n\n$usageMessage")

def parseSubcommandArgs(subcommand: String, rawArgs: Array[String]): Either[String, ParsedArgs] =
  var parsed = ParsedArgs(subcommand = subcommand)
  var i = 0
  var error: Option[String] = None

  while i < rawArgs.length && error.isEmpty do
    rawArgs(i) match
      case "--tenant" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(tenant = Some(rawArgs(i + 1))); i += 2
      case "--series-key" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(seriesKey = Some(rawArgs(i + 1))); i += 2
      case "--metric-key" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(metricKey = Some(rawArgs(i + 1))); i += 2
      case "--date" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(date = Some(rawArgs(i + 1))); i += 2
      case "--value" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(value = Some(rawArgs(i + 1))); i += 2
      case "--name" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(name = Some(rawArgs(i + 1))); i += 2
      case "--unit" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(unit = Some(rawArgs(i + 1))); i += 2
      case "--aggregation" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(aggregation = Some(rawArgs(i + 1))); i += 2
      case "--description" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(description = Some(rawArgs(i + 1))); i += 2
      case "--file" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(file = Some(rawArgs(i + 1))); i += 2
      case "--token" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(token = Some(rawArgs(i + 1))); i += 2
      case "--api-url" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(apiUrl = Some(rawArgs(i + 1))); i += 2
      case "--profile" if i + 1 < rawArgs.length =>
        parsed = parsed.copy(profile = rawArgs(i + 1)); i += 2
      case "--verbose" =>
        parsed = parsed.copy(verbose = true); i += 1
      case "--dry-run" =>
        parsed = parsed.copy(dryRun = true); i += 1
      case knownFlagMissingValue
          if Seq("--tenant", "--series-key", "--metric-key", "--date", "--value",
                 "--name", "--unit", "--aggregation", "--description", "--file",
                 "--token", "--api-url", "--profile")
               .contains(knownFlagMissingValue) =>
        error = Some(s"Flag $knownFlagMissingValue requires a value"); i += 1
      case unknownFlag =>
        error = Some(s"Unknown flag: $unknownFlag"); i += 1

  error match
    case Some(msg) => Left(msg)
    case None      => Right(parsed)

def usageMessage: String =
  """Usage: platform-metrics <subcommand> [options]
    |
    |Subcommands:
    |
    |  record-point   Record a single metric data point
    |    --tenant <id>          Tenant id (required)
    |    --series-key <key>     Series key (required)
    |    --metric-key <key>     Metric key (required)
    |    --date <YYYY-MM-DD>    Date of the data point (required)
    |    --value <number>       Numeric value (required)
    |
    |  record-points  Record many metric data points in one bulk request
    |    --tenant <id>          Tenant id (required)
    |    --file <path|->        JSON array of {series_key, metric_key, date, value} (required;
    |                           use '-' to read from stdin)
    |
    |  set-metric     Upsert metric metadata by (series_key, metric_key). Auto-creates the
    |                 metric if it does not exist; otherwise updates the metadata.
    |    --tenant <id>          Tenant id (required)
    |    --series-key <key>     Series key (required)
    |    --metric-key <key>     Metric key (required)
    |    --name <text>          Display name (optional)
    |    --unit <text>          Unit label, e.g. gpd (optional)
    |    --aggregation <agg>    avg | max | min (optional)
    |    --description <text>   Description (optional)
    |
    |Global options:
    |  --token <tok>            Platform API token (overrides env/config)
    |  --api-url <url>          API base URL (overrides env/config)
    |  --profile <name>         Config profile (default: default)
    |  --verbose                Print request/response details
    |  --dry-run                Print requests that would be sent, then exit 0
    |
    |Config file: ~/.platform/config
    |  default {
    |    api_url = "https://api.platform.com"
    |    token = "tok_xxxxxxxxxxxx"
    |  }
    |
    |Environment variables: PLATFORM_TOKEN, PLATFORM_API_URL""".stripMargin

// ── Config loading ─────────────────────────────────────────────────────────────

case class ResolvedConfig(token: String, apiUrl: String)

val configFilePath: String =
  Option(System.getenv("PLATFORM_CONFIG_FILE")).filter(_.nonEmpty)
    .getOrElse(System.getProperty("user.home") + "/.platform/config")

def checkConfigFilePermissions(): Unit =
  val path = Paths.get(configFilePath)
  if Files.exists(path) then
    Try {
      val perms = Files.getPosixFilePermissions(path)
      val tooPermissive = perms.contains(PosixFilePermission.GROUP_READ) ||
        perms.contains(PosixFilePermission.GROUP_WRITE) ||
        perms.contains(PosixFilePermission.OTHERS_READ) ||
        perms.contains(PosixFilePermission.OTHERS_WRITE)
      if tooPermissive then
        System.err.println(s"Warning: $configFilePath has permissions wider than 0600. Consider running: chmod 600 $configFilePath")
    }.recover {
      case _: java.nio.file.NoSuchFileException => ()
      case _: SecurityException => ()
      case _: UnsupportedOperationException => ()
    }

def loadConfig(parsed: ParsedArgs): Either[String, ResolvedConfig] =
  // Resolve token: CLI flag > env var > config file
  val tokenFromEnv = Option(System.getenv("PLATFORM_TOKEN")).filter(_.nonEmpty)
  val apiUrlFromEnv = Option(System.getenv("PLATFORM_API_URL")).filter(_.nonEmpty)

  // Parse config file once and read both keys from the single parsed Config
  val fileConfig: Option[Config] = loadConfigFile()
  val tokenFromFile: Option[String] = fileConfig.flatMap(c => readConfigKey(c, parsed.profile, "token"))
  val apiUrlFromFile: Option[String] = fileConfig.flatMap(c => readConfigKey(c, parsed.profile, "api_url"))

  val token = parsed.token
    .orElse(tokenFromEnv)
    .orElse(tokenFromFile)

  val apiUrl = parsed.apiUrl
    .orElse(apiUrlFromEnv)
    .orElse(apiUrlFromFile)

  (token, apiUrl) match
    case (None, _) =>
      Left(s"Missing platform token. Provide via --token, PLATFORM_TOKEN env var, or $configFilePath (profile '${parsed.profile}', key 'token')")
    case (_, None) =>
      Left(s"Missing API URL. Provide via --api-url, PLATFORM_API_URL env var, or $configFilePath (profile '${parsed.profile}', key 'api_url')")
    case (Some(tok), Some(url)) =>
      Right(ResolvedConfig(token = tok, apiUrl = url.stripSuffix("/")))

/** Parse the config file once. Returns None if the file does not exist, or
  * exits with a clear message if the file is present but malformed.
  */
def loadConfigFile(): Option[Config] =
  val file = new File(configFilePath)
  if !file.exists() then None
  else
    Try(ConfigFactory.parseFile(file)) match
      case Success(c) => Some(c)
      case Failure(configEx: ConfigException) =>
        System.err.println(s"Error parsing config file $configFilePath: ${configEx.getMessage}")
        sys.exit(ExitValidation)
      case Failure(ioEx) =>
        System.err.println(s"Error reading config file $configFilePath: ${ioEx.getMessage}")
        sys.exit(ExitValidation)

def readConfigKey(config: Config, profile: String, key: String): Option[String] =
  Try(config.getString(s"$profile.$key")).toOption

// ── Validation ────────────────────────────────────────────────────────────────

def validateDate(date: String): Either[String, String] =
  Try(java.time.LocalDate.parse(date)).toEither.left.map(_ => s"Invalid date format '$date'. Expected YYYY-MM-DD.").map(_ => date)

def validateNumericValue(value: String): Either[String, BigDecimal] =
  Try(BigDecimal(value)).toEither.left.map(_ => s"Invalid numeric value '$value'")

def validateAggregation(agg: String): Either[String, String] =
  agg match
    case "avg" | "max" | "min" => Right(agg)
    case invalidAgg            => Left(s"Invalid aggregation '$invalidAgg'. Must be avg, max, or min.")

// ── HTTP ───────────────────────────────────────────────────────────────────────

def buildAuthHeader(token: String): String =
  val credentials = s"$token:"
  "Basic " + Base64.getEncoder.encodeToString(credentials.getBytes("UTF-8"))

case class RequestSpec(
  method: String,
  url: String,
  body: String,
  authHeader: String
)

def printRequest(spec: RequestSpec, verbose: Boolean): Unit =
  if verbose then
    println(s"${spec.method} ${spec.url}")
    println(s"Authorization: Basic <REDACTED>")
    if spec.body.nonEmpty then println(s"Content-Type: application/json")
    if spec.body.nonEmpty then println(s"Body: ${spec.body}")
  else
    println(s"[dry-run] ${spec.method} ${spec.url}")
    if spec.body.nonEmpty then println(s"[dry-run] Body: ${spec.body}")

def executeRequest(spec: RequestSpec, verbose: Boolean): (Int, String) =
  if verbose then
    println(s"${spec.method} ${spec.url}")
    println(s"Authorization: Basic <REDACTED>")
    if spec.body.nonEmpty then println(s"Content-Type: application/json")
    if spec.body.nonEmpty then println(s"Body: ${spec.body}")

  val backend = HttpClientSyncBackend()
  try
    val baseReq = basicRequest
      .header("Authorization", spec.authHeader)

    val requestWithBody =
      if spec.body.nonEmpty then
        baseReq.header("Content-Type", "application/json").body(spec.body)
      else
        baseReq

    val request = spec.method match
      case "GET"             => requestWithBody.get(uri"${spec.url}")
      case "POST"            => requestWithBody.post(uri"${spec.url}")
      case "PUT"             => requestWithBody.put(uri"${spec.url}")
      case unsupportedMethod => sys.error(s"Unsupported HTTP method: $unsupportedMethod")

    val response = request.send(backend)
    val statusCode = response.code.code
    val responseBody = response.body match
      case Right(b) => b
      case Left(b)  => b

    if verbose then
      println(s"Response: $statusCode")
      println(s"Response body: $responseBody")

    (statusCode, responseBody)
  catch
    case e: Exception =>
      val msg = Option(e.getMessage).getOrElse(e.getClass.getSimpleName)
      System.err.println(s"Network error: $msg")
      sys.exit(ExitNetwork)
  finally
    backend.close()

def parseValidationErrors(body: String): List[String] =
  Try(Json.parse(body).as[Seq[ValidationError]].map(_.message).toList).getOrElse(Nil)

def handleResponse(statusCode: Int, body: String, successMsg: String): Unit =
  val category = statusCode / 100
  category match
    case 2 =>
      println(successMsg)
    case 4 =>
      val errors = parseValidationErrors(body)
      if errors.nonEmpty then
        errors.foreach(e => System.err.println(s"Error: $e"))
      else
        System.err.println(s"Error ($statusCode): $body")
      sys.exit(ExitValidation)
    case 5 =>
      System.err.println(s"Server error ($statusCode): $body")
      sys.exit(ExitServerError)
    // HTTP status codes are an open integer domain (1xx informational, and any future codes)
    case otherStatus =>
      System.err.println(s"Unexpected status ($statusCode): $body")
      sys.exit(ExitServerError)

// ── Required-field validation helpers ─────────────────────────────────────────

case class ValidatedRecordPointFlags(
  tenantId: String,
  seriesKey: String,
  metricKey: String,
  dateStr: String,
  value: BigDecimal
)

case class ValidatedSetMetricFlags(
  tenantId: String,
  seriesKey: String,
  metricKey: String,
  aggregation: Option[String]
)

def validateRecordPointFlags(parsed: ParsedArgs): Either[String, ValidatedRecordPointFlags] =
  for
    tenantId  <- parsed.tenant.toRight("--tenant is required")
    seriesKey <- parsed.seriesKey.toRight("--series-key is required")
    metricKey <- parsed.metricKey.toRight("--metric-key is required")
    dateStr   <- parsed.date.toRight("--date is required")
    valueStr  <- parsed.value.toRight("--value is required")
    _         <- validateDate(dateStr)
    bd        <- validateNumericValue(valueStr)
  yield ValidatedRecordPointFlags(tenantId, seriesKey, metricKey, dateStr, bd)

def validateSetMetricFlags(parsed: ParsedArgs): Either[String, ValidatedSetMetricFlags] =
  for
    tenantId    <- parsed.tenant.toRight("--tenant is required")
    seriesKey   <- parsed.seriesKey.toRight("--series-key is required")
    metricKey   <- parsed.metricKey.toRight("--metric-key is required")
    aggregation <- parsed.aggregation match
                     case None      => Right(None)
                     case Some(agg) => validateAggregation(agg).map(Some(_))
  yield ValidatedSetMetricFlags(tenantId, seriesKey, metricKey, aggregation)

def failValidation(msg: String): Nothing =
  System.err.println(msg)
  sys.exit(ExitValidation)

// ── record-point ──────────────────────────────────────────────────────────────

def runRecordPoint(parsed: ParsedArgs, config: ResolvedConfig): Unit =
  val flags = validateRecordPointFlags(parsed) match
    case Left(err) => failValidation(err)
    case Right(v)  => v

  val url = s"${config.apiUrl}/${flags.tenantId}/metrics/points"

  val form = PointForm(
    seriesKey = flags.seriesKey,
    metricKey = flags.metricKey,
    date = LocalDate.parse(flags.dateStr),
    value = flags.value,
  )
  val body = Json.stringify(Json.toJson(form))

  val spec = RequestSpec(
    method     = "POST",
    url        = url,
    body       = body,
    authHeader = buildAuthHeader(config.token)
  )

  if parsed.dryRun then
    printRequest(spec, parsed.verbose)
    sys.exit(ExitOk)

  val (statusCode, responseBody) = executeRequest(spec, parsed.verbose)

  val successMsg = if statusCode / 100 == 2 then
    Try {
      val id = (Json.parse(responseBody) \ "id").asOpt[String].getOrElse("?")
      s"OK metric_point=$id"
    }.getOrElse("OK")
  else ""

  handleResponse(statusCode, responseBody, successMsg)

// ── set-metric (server-side upsert by keys) ───────────────────────────────────

def runSetMetric(parsed: ParsedArgs, config: ResolvedConfig): Unit =
  val flags = validateSetMetricFlags(parsed) match
    case Left(err) => failValidation(err)
    case Right(v)  => v

  val unit = parsed.unit match
    case None    => None
    case Some(u) => MetricUnit.fromString(u) match
      case Some(known) => Some(known)
      case None        => failValidation(s"Invalid unit '$u'. Valid: ${MetricUnit.all.map(_.toString).mkString(", ")}.")

  val form = MetricUpsertForm(
    seriesKey = flags.seriesKey,
    metricKey = flags.metricKey,
    name = parsed.name,
    unit = unit,
    aggregation = flags.aggregation.map(Aggregation.apply),
    description = parsed.description,
  )
  val body = Json.stringify(Json.toJson(form))

  val url = s"${config.apiUrl}/${flags.tenantId}/metrics/metrics"
  val spec = RequestSpec(
    method     = "POST",
    url        = url,
    body       = body,
    authHeader = buildAuthHeader(config.token)
  )

  if parsed.dryRun then
    printRequest(spec, parsed.verbose)
    sys.exit(ExitOk)

  val (statusCode, responseBody) = executeRequest(spec, parsed.verbose)

  val successMsg = if statusCode / 100 == 2 then
    Try {
      val id = (Json.parse(responseBody) \ "id").asOpt[String].getOrElse("?")
      s"OK metric=$id"
    }.getOrElse("OK")
  else ""

  handleResponse(statusCode, responseBody, successMsg)

// ── record-points (bulk) ──────────────────────────────────────────────────────

case class ValidatedRecordPointsFlags(tenantId: String, forms: Seq[PointForm])

def readFileOrStdin(path: String): Either[String, String] =
  if path == "-" then
    Right(scala.io.Source.stdin.mkString)
  else
    val f = new File(path)
    if !f.exists() then
      Left(s"File not found: $path")
    else
      Try(scala.io.Source.fromFile(f).mkString).toEither.left.map(e =>
        s"Error reading $path: ${Option(e.getMessage).getOrElse(e.getClass.getSimpleName)}"
      )

/** Parse and validate the JSON body as a [point_form] array using the apibuilder-
  * generated Reads. Lets play-json handle field presence, type coercion, and
  * date parsing — no hand-rolled JSON traversal here.
  *
  * Note: the generated joda LocalDate Reads parses via `parseLocalDate`, which
  * throws `IllegalArgumentException` on a malformed date instead of yielding
  * `JsError`. We catch that here and surface it as an "invalid date" error so the
  * caller sees a clear message instead of a stack trace.
  */
def parsePointFormsJson(raw: String): Either[String, Seq[PointForm]] =
  Try(Json.parse(raw)).toEither.left.map(e =>
    s"Invalid JSON: ${Option(e.getMessage).getOrElse(e.getClass.getSimpleName)}"
  ).flatMap { json =>
    if !json.isInstanceOf[play.api.libs.json.JsArray] then
      Left("Body must be a JSON array of point_form objects")
    else
      Try(json.validate[Seq[PointForm]]).toEither.left.map { e =>
        s"invalid date or field value: ${Option(e.getMessage).getOrElse(e.getClass.getSimpleName)}"
      }.flatMap {
        case JsSuccess(forms, _) => Right(forms)
        case JsError(errors)     => Left(formatJsErrors(errors))
      }
  }

/** Render JsError into a readable multi-line string. Each entry mentions the
  * offending JSON path (e.g. `(0)/date`) and the reason (e.g. `error.path.missing`).
  */
def formatJsErrors(errors: collection.Seq[(JsPath, collection.Seq[JsonValidationError])]): String =
  errors.map { case (path, errs) =>
    val pathStr = path.toString
    val msgs = errs.map { e =>
      // Translate play-json's stock keys into something a human-friendly. We special-case
      // `error.path.missing` so the test (and the user) sees the field name plainly.
      e.message match
        case "error.path.missing" =>
          val field = path.path.lastOption.fold(pathStr)(_.toJsonString.stripPrefix("."))
          s"missing required field: $field"
        case other => other
    }.mkString(", ")
    s"$pathStr: $msgs"
  }.mkString("\n")

def validateRecordPointsFlags(parsed: ParsedArgs): Either[String, ValidatedRecordPointsFlags] =
  for
    tenantId <- parsed.tenant.toRight("--tenant is required")
    path     <- parsed.file.toRight("--file is required (use '-' for stdin)")
    raw      <- readFileOrStdin(path)
    forms    <- parsePointFormsJson(raw)
  yield ValidatedRecordPointsFlags(tenantId = tenantId, forms = forms)

def runRecordPoints(parsed: ParsedArgs, config: ResolvedConfig): Unit =
  val flags = validateRecordPointsFlags(parsed) match
    case Left(err) => failValidation(err)
    case Right(v)  => v

  val url  = s"${config.apiUrl}/${flags.tenantId}/metrics/points/bulk"
  val body = Json.stringify(Json.toJson(flags.forms))
  val spec = RequestSpec(
    method     = "POST",
    url        = url,
    body       = body,
    authHeader = buildAuthHeader(config.token)
  )

  if parsed.dryRun then
    printRequest(spec, parsed.verbose)
    sys.exit(ExitOk)

  val (statusCode, responseBody) = executeRequest(spec, parsed.verbose)

  val successMsg = if statusCode / 100 == 2 then s"OK n_points=${flags.forms.size}" else ""

  handleResponse(statusCode, responseBody, successMsg)

// ── Entry point ────────────────────────────────────────────────────────────────

val parsedArgs: ParsedArgs = parseArgs(args) match
  case Left(msg) =>
    System.err.println(msg)
    sys.exit(ExitValidation)
  case Right(p) => p

checkConfigFilePermissions()

val config: ResolvedConfig = loadConfig(parsedArgs) match
  case Left(msg) =>
    System.err.println(msg)
    sys.exit(ExitMissingToken)
  case Right(c) => c

parsedArgs.subcommand match
  case "record-point"  => runRecordPoint(parsedArgs, config)
  case "record-points" => runRecordPoints(parsedArgs, config)
  case "set-metric"    => runSetMetric(parsedArgs, config)
  case unhandledSubcommand =>
    System.err.println(s"Internal error: unhandled subcommand '$unhandledSubcommand'")
    sys.exit(ExitValidation)
