require 'open3'
require 'set'

# Classifies schema-evolution-manager migration scripts by whether they are safe
# to apply while the CURRENTLY DEPLOYED code is still serving traffic.
#
# A schema release is one of two things, and they want opposite orderings:
#
#   EXPANDING  - adds tables, columns, indexes, constraints. The running code
#                does not know about any of it, so applying it early is free and
#                applying it late breaks the new code. Migrate BEFORE the app.
#   CONTRACTING - removes or renames something. The running code still selects
#                it, so applying it early breaks the OLD code for the whole
#                length of the app's build and rollout. Migrate AFTER the app.
#
# Only the first half of that was ever enforced (`dev deploy all` applied every
# pending migration in Phase 1 and released the apps in Phase 2), and production
# paid for it twice in two days:
#
#   2026-08-03  11x  ERROR: column re.business_line_id does not exist
#                    (dropped by platform #1947) - 500s on the revenue category,
#                    forecast and renewals endpoints.
#   2026-08-04  37x  ERROR: relation "playbook.membership_categories" does not exist
#                    (dropped by platform #1988) - 500s across the members
#                    attendance/revenue/retention dashboard, plus
#                    "membership-category normalize failed; skipping" for 11 clubs.
#
# Neither PR was wrong. The ORDER was, and nothing was checking it.
#
# One shape this does NOT rescue: a script that expands and contracts at once,
# of which a RENAME is the pure case (20260803-142920.sql renamed
# revenue_entries.business_line_id to revenue_category_id). Applied early it
# breaks the old code; applied late it breaks the new code. Ordering can only
# choose which side pays, and choosing "late" at least shortens the window from
# the app's whole build-and-rollout to the seconds between Phase 2 and Phase 3.
# The actual cure for a rename is two releases - add the new name, deploy, then
# drop the old one - and nothing here can substitute for that.
#
# The classification errs toward EXPANDING on purpose. A false "contracting"
# defers a migration the new code needs until after its rollout, which is the
# same failure in the other direction - so the destructive keywords are named
# explicitly and everything else, including the DROP INDEX / DROP CONSTRAINT /
# DROP DEFAULT / DROP NOT NULL that show up in ordinary additive scripts, is
# left alone.
module SchemaScripts
  # A DROP of one of these removes a name the running code may still be issuing
  # SQL against, and Postgres answers that with `does not exist` rather than
  # anything the application can recover from.
  DROPPED_OBJECTS = %w[
    table schema view sequence type function column
  ].freeze

  # A DROP of one of these changes the shape of the database without removing a
  # name any query mentions. Slower, or less constrained, never `does not exist`.
  SAFE_DROPS = %w[
    constraint index default trigger rule policy owned
  ].freeze

  # `ALTER TABLE t DROP c` - Postgres makes the COLUMN keyword optional, so the
  # bare form has to be recognized by what it is NOT.
  #
  # The `\b` closing the lookahead is load-bearing. Alternation matches a PREFIX,
  # so without it any column whose name merely STARTS with one of these keywords
  # satisfied the lookahead and the whole statement fell through as expanding:
  # `drop type_id`, `drop trigger_source`, `drop default_locale`, `drop
  # not_before`, `drop indexed_at` are all ordinary column names and all read as
  # additive. That is not a cosmetic misclassification - `SchemaScripts
  # .contracting` is what sorts a release into deploy Phase 1 (before the app) or
  # Phase 3 (after it), so a `DROP type_id` was applied while the running code
  # still selected the column, which is the `column ... does not exist` outage
  # this module was written for (ISS-317).
  BARE_COLUMN_DROP = /\bdrop\s+(?:if\s+exists\s+)?(?!(?:#{(DROPPED_OBJECTS + SAFE_DROPS + %w[not if]).join('|')})\b)[a-z_"][\w"]*/

  DROP_OBJECT = /\bdrop\s+(?:materialized\s+view|#{DROPPED_OBJECTS.join('|')})\b/

  # Renaming is a drop and an add issued as one statement: the old name stops
  # resolving the instant it commits.
  RENAME = /\brename\s+(?:column\b|to\b)/

  # ...except an index, which no query names. Renaming one is invisible to the
  # application, and pairing it with the column rename it belongs to is the
  # house style, so leaving it in would defer releases that only reindex.
  RENAME_EXEMPT = /\Aalter\s+index\b/

  # Strips `-- line` and `/* block */` comments so a statement that only
  # mentions a DROP in prose - which every generated migration does, because the
  # DAO codegen writes the intent above the DDL - is not read as one.
  # Forced to UTF-8 and scrubbed first. Migration comments carry em dashes and
  # smart quotes, and `File.read` tags the string with Encoding.default_external
  # — US-ASCII whenever the caller's locale is unset, which is exactly what a
  # release running under launchd or ssh gets. A regexp against that raises
  # `invalid byte sequence`, so the classifier would have died mid-deploy on the
  # first script with a typographic character in it.
  def SchemaScripts.strip_comments(sql)
    sql.dup.force_encoding(Encoding::UTF_8).scrub("")
      .gsub(%r{/\*.*?\*/}m, " ").gsub(/--[^\n]*/, " ")
  end

  # The destructive statements in one script's SQL, verbatim (whitespace
  # collapsed) so the operator sees exactly what is about to be removed rather
  # than being told a file "is destructive".
  #
  # Splitting on `;` is deliberately naive. A dollar-quoted function body can
  # carry one, which at worst splits a statement into two fragments - both are
  # still scanned, so a real DROP inside a function body is still reported.
  def SchemaScripts.contracting_statements(sql)
    body = strip_comments(sql)
    recreated = created_objects(body)
    body.split(";").filter_map do |raw|
      statement = raw.strip.gsub(/\s+/, " ")
      next if statement.empty?
      normalized = statement.downcase
      next if normalized =~ RENAME_EXEMPT
      next unless normalized =~ DROP_OBJECT ||
                  normalized =~ RENAME ||
                  (normalized.include?("alter table") && normalized =~ BARE_COLUMN_DROP)
      next if recreated.include?(dropped_object_name(normalized))
      statement
    end
  end

  # `drop table if exists x; create table x (...)` is not a contraction, it is a
  # re-runnable create — and it is how a large share of the generated migrations
  # open, so reading it as one would defer half of all purely additive releases
  # until after their app, which is the same outage in the other direction.
  #
  # Matched on the UNQUALIFIED name so `drop table if exists executions` pairs
  # with `create table playbook.executions`. Dropping `a.foo` while creating an
  # unrelated `b.foo` in one script would be missed; nothing in the schema does
  # that, and the alternative misses the far more common qualification mismatch.
  def SchemaScripts.created_objects(body)
    body.downcase.scan(
      /\bcreate\s+(?:or\s+replace\s+)?(?:unique\s+)?(?:materialized\s+view|table|view|sequence|type|function|schema)\s+(?:if\s+not\s+exists\s+)?([\w".]+)/
    ).flatten.map { |name| unqualify(name) }.to_set
  end

  # The object a DROP names, unqualified, or nil when the statement is a rename,
  # a bare column drop, or dynamic SQL whose target is a format placeholder.
  def SchemaScripts.dropped_object_name(normalized)
    match = normalized.match(
      /\bdrop\s+(?:materialized\s+view|#{DROPPED_OBJECTS.join('|')})\s+(?:if\s+exists\s+)?([\w".]+)/
    )
    match && unqualify(match[1])
  end

  def SchemaScripts.unqualify(name)
    name.delete('"').split(".").last
  end

  # Migration scripts ADDED between two git refs, oldest first.
  #
  # Added-only (`--diff-filter=A`) because that is what schema-evolution-manager
  # will apply: it keys on filename, so a script edited after it was applied
  # somewhere is not re-run and must not be re-classified.
  def SchemaScripts.added_scripts(repo_dir, from_ref, to_ref)
    out, status = Open3.capture2(
      "git", "diff", "--diff-filter=A", "--name-only", "#{from_ref}..#{to_ref}", "--", "scripts",
      chdir: repo_dir
    )
    return [] unless status.success?
    out.split("\n").map(&:strip).select { |f| f.end_with?(".sql") }.sort
  end

  # { script path => [destructive statements] } for every script added between
  # the two refs that removes something. Empty means the release is expanding
  # and can be applied ahead of the code that ships with it.
  def SchemaScripts.contracting(repo_dir, from_ref, to_ref)
    added_scripts(repo_dir, from_ref, to_ref).each_with_object({}) do |path, acc|
      full = File.join(repo_dir, path)
      next unless File.file?(full)
      statements = contracting_statements(File.read(full))
      acc[path] = statements unless statements.empty?
    end
  end

  # The tag released immediately before `tag`, or nil when `tag` is the first.
  # Version-sorted rather than date-sorted: sem tags are `x.y.z` and a re-tagged
  # release would otherwise reorder them.
  def SchemaScripts.previous_tag(repo_dir, tag)
    out, status = Open3.capture2("git", "tag", "--list", "--sort=-v:refname", chdir: repo_dir)
    return nil unless status.success?
    tags = out.split("\n").map(&:strip).reject(&:empty?)
    index = tags.index(tag)
    return nil if index.nil?
    tags[index + 1]
  end

  # Operator-facing rendering of `contracting`: script by script, statement by
  # statement.
  def SchemaScripts.describe(contracting)
    contracting.map do |path, statements|
      ["  #{File.basename(path)}"] + statements.map { |s| "      #{s}" }
    end.flatten.join("\n")
  end

  # What release-db prints before applying a contracting release by hand.
  #
  # It names the statements rather than asking "are you sure": the operator's
  # real question is "does anything still SELECT this", and that is answerable
  # only by seeing which objects go away.
  def SchemaScripts.contracting_warning(tag, contracting)
    <<~TEXT
      #{tag} is a CONTRACTING release — it removes schema objects that code may still name:

      #{describe(contracting)}

      Every app running against this database must ALREADY be deployed with code that no
      longer references them. Applying this first means every request that touches one of
      these objects answers `does not exist` until the app finishes rolling out.

      `dev deploy all` orders this for you: it releases the app first (Phase 2) and this
      database afterwards (Phase 3). Prefer that over applying it by hand.
    TEXT
  end
end
