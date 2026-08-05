# The repos the weekly `api lint` sweep covers — one child issue per name in
# `REPOS`, filed by the `api-lint` producer in agent/producers.yml.
#
# This list lives in code rather than in the playbook's prose because the way it
# goes wrong is silent. A repo that starts owning apibuilder specs and is never
# added to the sweep is simply never linted, and nothing anywhere says so. With
# the list here, test/test_agent_cron_migration.rb can tie it to
# ApiProducers::REPOS — the spec producers `api` itself resolves from — so a
# fourth producer fails the suite until it is either linted or declared
# UNSUPPORTED below. That is the same guard `Dependencies::Updates::APPS` gives
# the nightly upgrade epic (ISS-397).
module ApiLint

  # Every repo under ~/code that owns apibuilder spec files.
  #
  # A superset of ApiProducers::REPOS, and deliberately so: that constant lists
  # the producers OTHER repos resolve specs from, and a repo whose specs nobody
  # else consumes still owns specs that still drift.
  SPEC_OWNERS = %w[platform acumen dependency lib-ai].freeze

  # Spec owners `api lint` cannot sweep today, and why.
  #
  # Named here rather than quietly dropped from SPEC_OWNERS: a repo deleted from
  # a list is a repo nobody remembers to put back once its blocker clears, which
  # is the same silent failure this file exists to prevent.
  UNSUPPORTED = {
    "dependency" =>
      "No .api/config.pkl. It is still on the legacy `.apibuilder/config` (org `flow`, " \
      "play_2_8_client generators) and has not been pushed since 2025-12. `api lint` " \
      "exits immediately with \"No .api/config.pkl found\" — verified against a fresh " \
      "clone on 2026-08-05 — so a child for it would burn a lease every week on a run " \
      "that cannot succeed. Move it back into REPOS by giving the repo an " \
      "`.api/config.pkl`, or retire the repo.",
  }.freeze

  # What the producer actually files children for.
  REPOS = (SPEC_OWNERS - UNSUPPORTED.keys).freeze
end
