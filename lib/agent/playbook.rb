require 'agent/checkout'
require 'agent/paths'

# The playbook a producer's issue POINTS AT, and how a claiming runner resolves
# that pointer (ISS-505).
#
# The pointer exists because the alternative — copying the playbook's full text
# into every filed issue — freezes it. An issue filed on Friday and claimed on
# Tuesday would run Friday's procedure, and every improvement pushed to
# `agent/bodies/*.md` in between would apply to nothing already in the queue. The
# nightly producers exist precisely so these runbooks improve continuously, so
# there must be ONE copy of the plan and it must be the current one.
#
# THREE PROPERTIES, and none of them is decoration:
#
#   resolved at CLAIM time   Not at file time. Pinning a sha when the issue is
#                            filed recreates the snapshot with extra steps.
#                            Latest-at-claim is the entire point.
#   the sha is RECORDED      The runner's devops HEAD goes on the issue as a
#                            comment, with a permalink, so a run stays
#                            reproducible after the file changes and a runner on
#                            a stale checkout is visible rather than theoretical.
#   an abstract stays INLINE The filed body keeps the playbook's heading and
#                            opening paragraph. A body that is nothing but a path
#                            renders as an empty box in admin, and the platform
#                            has no devops checkout to resolve it server-side.
#                            Only the long procedure moves.
#
# WHAT DOES NOT MOVE: a `file_when: check_fails` producer's check output. That is
# run-specific evidence, not a standing procedure, and it stays inline in the
# body where it was found.
module Agent
  module Playbook
    # A pointer that does not resolve on the runner is a HARD failure, never a
    # silent fallback to generic triage. ISS-360 is the cautionary tale: a
    # producer ported without its playbook fell back to
    # claude-issues/default-body.md and filed issues instead of shipping PRs for
    # a week, with nothing anywhere saying so.
    class MissingError < StandardError; end

    REPO_URL = "https://github.com/mbryzek/devops".freeze

    # Substituted into a shared playbook so one file can carry the exact command
    # each child of an epic runs (`--app {child}`). Agent::Producers aliases this
    # rather than declaring its own — the producer writes the token into the
    # pointer and the runner resolves it, so the two must be the same literal.
    CHILD_TOKEN = "{child}".freeze

    # THE contract line between the producer that writes an issue body and the
    # runner that later reads it back. Deliberately strict: anchored to the start
    # of a line, backticked, and rooted at `agent/`, so prose that merely
    # mentions a playbook path — including an indented example in an issue
    # describing this very mechanism — cannot be mistaken for a pointer.
    MARKER = "Playbook:".freeze
    MARKER_RE = /^#{MARKER} `(agent\/[^`\n]+)`(?: \(target: ([^)\n]+)\))?[ \t]*$/.freeze

    # The pointer is read back out of an issue body, which is human-editable, so
    # the path is treated as untrusted input: a whitelist of characters, a `.md`
    # extension, and no `..` segment (checked separately — the pattern alone
    # would admit `agent/bodies/../../x.md`).
    SAFE_PATH_RE = %r{\Aagent/[A-Za-z0-9][A-Za-z0-9._/-]*\.md\z}.freeze

    Pointer = Struct.new(:path, :target, keyword_init: true)

    # A pointer that has been read off THIS runner's disk: the text it actually
    # got, and the sha it got it at.
    Resolved = Struct.new(:path, :target, :text, :sha, keyword_init: true) do
      def short_sha = Agent::Checkout.short(sha)
      def permalink = Agent::Playbook.permalink(path, sha)
      # The exact shape ISS-505 asks the session to record:
      #   Playbook: agent/bodies/slow-query-review.md @ a1b2c3d
      def label = "#{path} @ #{short_sha}"
    end

    module_function

    # The block a producer files INSTEAD of the playbook's full text: the
    # playbook's own heading and opening paragraph, then the pointer and a
    # permalink to the current version. Everything here is derived from the file,
    # so there is still exactly one copy of the plan.
    def pointer_block(path, target: nil)
      text = read(path, target: target)
      <<~BLOCK.strip
        ## Playbook

        #{abstract(text)}

        #{pointer_line(path, target: target)}

        The procedure itself is deliberately NOT copied here. The claiming runner reads it
        from its own devops checkout when this issue is claimed, so the session runs the
        CURRENT version rather than a copy frozen the night this was filed, and records the
        sha it read as a comment below. Latest:
        #{permalink(path, nil)}
      BLOCK
    end

    def pointer_line(path, target: nil)
      suffix = target.to_s.empty? ? "" : " (target: #{target})"
      "#{MARKER} `#{path}`#{suffix}"
    end

    # The pointer in an issue body, or nil when there is none — which is every
    # human-written issue and every issue filed before this existed, both of
    # which carry their brief inline and must keep working untouched.
    def pointer_in(body)
      match = MARKER_RE.match(body.to_s)
      return nil unless match
      Pointer.new(path: match[1], target: match[2])
    end

    # nil (no pointer) or a Resolved. Raises MissingError when a pointer IS
    # present and this runner cannot read it — see MissingError.
    def resolve_in(body)
      pointer = pointer_in(body)
      pointer && resolve(pointer)
    end

    def resolve(pointer)
      Resolved.new(path: pointer.path, target: pointer.target,
                   text: read(pointer.path, target: pointer.target),
                   sha: Agent::Checkout.head_sha)
    end

    # The playbook's text on this machine, with `{child}` resolved.
    def read(path, target: nil)
      text = File.read(absolute(path))
      target.to_s.empty? ? text.strip : text.strip.gsub(CHILD_TOKEN, target.to_s)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      raise MissingError, "playbook `#{path}` did not resolve in #{Agent::Paths.devops_repo} (#{e.class})"
    end

    # Rejects anything that is not a plain `.md` under `agent/`, then confirms
    # the expansion really landed inside the checkout — the pattern is the rule
    # and this is the proof, because a path read out of an issue body is input.
    def absolute(path)
      raise MissingError, "playbook path `#{path}` is not a path under agent/" unless SAFE_PATH_RE.match?(path.to_s)
      raise MissingError, "playbook path `#{path}` may not traverse upward" if path.to_s.split("/").include?("..")
      root = File.expand_path(Agent::Paths.devops_repo)
      resolved = File.expand_path(path.to_s, root)
      raise MissingError, "playbook path `#{path}` escapes #{root}" unless resolved.start_with?("#{root}/")
      resolved
    end

    # `agent/bodies/x.md` from the absolute path Agent::Producers validated at
    # parse time. Repo-relative rather than agent-relative because that is what a
    # GitHub permalink needs, and one form used everywhere cannot drift.
    def repo_relative(absolute_path)
      return nil if absolute_path.nil?
      root = "#{File.expand_path(Agent::Paths.devops_repo)}/"
      File.expand_path(absolute_path).delete_prefix(root)
    end

    # A nil sha means the runner is not a git checkout at all, which is already
    # reported elsewhere; `main` is the honest link in that case rather than a
    # broken one.
    def permalink(path, sha)
      "#{REPO_URL}/blob/#{sha.to_s.empty? ? 'main' : sha}/#{path}"
    end

    # The heading and the opening paragraph — the one part that stays inline in
    # the filed issue. Derived, never authored separately: an `abstract:` field
    # in producers.yml would be a second copy of the summary, drifting from the
    # playbook exactly the way the full text used to.
    def abstract(text)
      lines = text.to_s.strip.lines.map(&:rstrip)
      heading = lines.first.to_s.start_with?("# ") ? lines.shift.sub(/\A#\s+/, "") : nil
      lines.shift while !lines.empty? && lines.first.empty?
      paragraph = lines.take_while { |line| !line.empty? }.join("\n").strip
      [heading && "**#{heading}**", paragraph].compact.reject(&:empty?).join("\n\n")
    end

    # Every playbook must open `# Heading` + blank + a paragraph, because that
    # opening IS the abstract the filed issue renders. Enforced at PARSE time
    # (Agent::Producers), so a playbook rewritten into a shape that abstracts to
    # nothing fails the next tick rather than filing an empty-looking issue.
    def abstracts_cleanly?(text)
      lines = text.to_s.strip.lines.map(&:rstrip)
      return false unless lines.first.to_s.match?(/\A#\s+\S/)
      lines.shift
      lines.shift while !lines.empty? && lines.first.empty?
      !lines.first.to_s.strip.empty?
    end
  end
end
