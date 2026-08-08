require 'agent/redact'

# The shell startup files, made safe to READ (ISS-1035).
#
# WHY THIS EXISTS. Two of this fleet's shell startup files carry a human's own
# third-party credentials as plaintext literals: a Jira API token in `~/.zshrc`
# and an Artifactory password in `~/.alias`, which `~/.zprofile` sources
# unconditionally. Reading those files is not a careless act — it is the ONLY
# way to answer an ordinary question about this fleet. ISS-1033 was "where is
# `alias ps='ps -ax'` defined?", and answering it correctly put both credentials
# into a session transcript. ISS-1034 sends a human to append a line to
# `~/.zprofile`; the ISS-1033 doctor section names `~/.alias` out loud as the
# file to look in. The next session to touch shell configuration lands in the
# same place.
#
# So the fix cannot be "do not read them". A rule with no sanctioned alternative
# is a rule that gets broken by whoever actually has to answer the question.
# This is the alternative: the same files, the same structure, with the values
# taken out.
#
# WHAT THIS IS NOT. It is not a second `Agent::Redact`. Redact is a PATTERN NET
# over text you have no choice but to show — a process command line, where the
# rest of the argv is the diagnosis and cannot be dropped. Its own comment is
# honest about the cost: "a novel token shape passes through, so this is a net,
# not a seal."
#
# A file is the case where you DO have a choice, so this inverts the default.
# Redact asks "does this look like a secret?" and shows what it does not
# recognise. This asks "is this value STRUCTURAL — a path, a variable
# reference, a flag, a number?" and hides everything else, whatever it is
# called. That inversion is the entire point of the module, and it is the one
# property that must not be weakened.
#
# It matters because the name is exactly what this fleet cannot know. Redact's
# SECRET_NAME matches KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH, which is a good net
# for names people usually pick, and `JIRA_PAT` or `ARTIFACTORY_PW` defeats it
# completely. Building a sanctioned reader on a name net would produce the worst
# available outcome: a session that read a credential from the tool it was told
# to trust instead of the file it was told to avoid.
#
# WHAT IS STILL ONLY A NET, stated so nobody mistakes the seal for total. The
# seal covers ASSIGNMENT VALUES, which is where a credential in a startup file
# lives and where both of ISS-1035's are. A credential embedded somewhere else —
# inside an `alias`, inside a function body, inside a comment — is covered only
# by Redact's patterns, because hiding those would take the alias bodies and
# `source` lines with them and destroy the only reason to run this at all.
module Agent
  module Dotfiles
    # Distinct from Redact::PLACEHOLDER, and the difference carries information
    # an operator acts on. `[redacted]` means a pattern POSITIVELY identified a
    # credential — that assignment is a finding, go move it to the env repo.
    # `[hidden]` means only that the value was not structural, which is the
    # normal state of most ordinary settings. Collapsing the two would bury the
    # handful of real findings in a list of `LANG` and `EDITOR`.
    HIDDEN = "[hidden]".freeze

    # zsh's own startup order, which is also the order a reader wants them in.
    # `.zlogin` is here for completeness; nothing on this fleet uses it.
    STARTUP = %w[.zshenv .zprofile .zshrc .zlogin].freeze

    # How far to chase `source` lines. `~/.alias` is depth 1 from `~/.zprofile`,
    # which is the case that matters; 2 covers a file that sources a file.
    # Deeper targets are REPORTED and not followed — a startup chain that long is
    # not a hand-maintained dotfile, and silently walking into one is how this
    # command starts printing nvm.
    MAX_DEPTH = 2

    # A followed file this large is not a dotfile — it is a vendored script
    # (`nvm.sh` is ~4000 lines). Reported by size and not shown, because the
    # only thing flooding the output achieves is that nobody reads any of it.
    # Naming a path explicitly on the command line bypasses this: the guard is
    # about what gets pulled in UNASKED, not about what you may look at.
    MAX_AUTO_BYTES = 64 * 1024

    # One shell assignment, in the forms a startup file actually uses. The value
    # is "the rest of the line", deliberately: a trailing `# comment`, a `&&`,
    # or a second statement all get hidden along with it, and hiding more than
    # necessary is the direction this module is allowed to be wrong in.
    ASSIGNMENT = /\A(\s*(?:export\s+|readonly\s+|local\s+|typeset\s+(?:-\w+\s+)*|declare\s+(?:-\w+\s+)*)?)
                   ([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/x.freeze

    # `source FILE` / `. FILE`, at the start of a line OR after a `&&`, `||` or
    # `;`. The guarded form is not an edge case — `[ -f ~/.alias ] && source
    # ~/.alias` is how a dotfile sources anything it is not certain exists, and
    # an anchored pattern would have quietly stopped following `~/.alias`, which
    # is one of the two files this whole module was written for.
    SOURCE = /(?:\A|&&|\|\||;)\s*(?:source|\.)\s+(\S+)/.freeze

    # ---- what counts as a STRUCTURAL value, i.e. one safe to show ----

    # A `$VAR` or `${VAR}`, or an ordinary path segment. `$` is excluded from
    # the second alternative on purpose, so `pa$$word` matches neither and is
    # hidden. `=` is excluded so base64 padding cannot ride through as a
    # segment.
    SEGMENT = /(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[A-Za-z0-9_.@%+-]+|\*)/.freeze

    # One path: optional `~` or `/` root, then segments joined by `/`.
    PATH = %r{\A(?:~|\.{1,2})?/?#{SEGMENT}(?:/#{SEGMENT})*/?\z|\A~/?\z}.freeze

    # A number or a boolean. Never a credential, and `HISTSIZE=10000` is exactly
    # the kind of line whose value a reader wants.
    LITERAL = /\A(?:\d+|true|false|yes|no|on|off)\z/i.freeze

    # `-ax`, `-Xms40G`, `--color=auto`. A credential does not begin with a dash,
    # and `SBT_OPTS="-Xms40G -Xmx40G"` is a value the fleet debugs against
    # (ISS-753) — hiding it would make this command useless for the one
    # assignment sessions are most often sent to look at.
    FLAG = /\A--?[A-Za-z][\w.=:,+-]*\z/.freeze

    # A rendered line. `state` is `:shown`, `:hidden` or `:redacted`, and `name`
    # is the variable an assignment binds (nil otherwise) — a NAME is metadata,
    # not a secret, and printing it is what makes a finding actionable.
    Line = Struct.new(:number, :text, :state, :name, keyword_init: true) do
      def assignment? = !name.nil?
      def credential? = state == :redacted
      def opaque? = state == :hidden
    end

    # One startup file. `sourced_by` is the display path that pulled it in, nil
    # for the four zsh reads itself. `note` replaces `lines` when the file was
    # found but deliberately not shown.
    #
    # `resolves_to` is set when the startup file is a SYMLINK, which on this
    # fleet is the normal case rather than the exception — every one of them
    # points into a `~/code/misc/env` checkout. It is reported because it
    # changes what remediation means: the file to edit is the one in the
    # checkout, and a credential that lives there has been COMMITTED, so moving
    # it out of the working tree does not take it out of the history.
    File_ = Struct.new(:display, :path, :lines, :sourced_by, :note, :resolves_to, keyword_init: true) do
      def shown? = note.nil?
      def credentials = (lines || []).select(&:credential?)
      def opaque = (lines || []).select(&:opaque?)
    end

    module_function

    # Every startup file zsh reads, plus the files they source, in read order,
    # with every line already safe. THE one entry point — nothing else in this
    # repo opens a dotfile, so there is no second path that could forget to
    # redact.
    #
    # A file that does not exist is simply absent from the result: the four are
    # a candidate list, not a requirement, and "MISSING ~/.zlogin" would be a
    # finding about nothing.
    def read(home: Dir.home, paths: nil)
      if paths && !paths.empty?
        return Array(paths).filter_map { |p| render(::File.expand_path(p), home: home, sourced_by: nil, forced: true) }
      end

      out = []
      seen = {}
      STARTUP.each { |name| collect(::File.join(home, name), home: home, sourced_by: nil, depth: 0, seen: seen, out: out) }
      out
    end

    # The credential-shaped assignments across every startup file — what the
    # doctor reports and what a human has to go fix. Never carries a value:
    # these are built from already-rendered lines, so this cannot leak even if a
    # caller prints the whole thing.
    def findings(files) = files.flat_map { |f| f.credentials.map { |l| [f, l] } }

    # ---- collection ----

    # Dedup is on the REALPATH and display is on the path that was asked for.
    # Both halves matter here: every startup file on this fleet is a symlink
    # into one checkout, so realpath is what makes a `source` cycle terminate,
    # and the logical name is what a reader recognises — `~/code/misc/env/.zshrc`
    # alone does not say "this is your .zshrc".
    def collect(path, home:, sourced_by:, depth:, seen:, out:)
      real = begin
        ::File.realpath(path)
      rescue SystemCallError
        return
      end
      return if seen[real]
      seen[real] = true
      return unless ::File.file?(real) && ::File.readable?(real)

      file = render(real, home: home, sourced_by: sourced_by, forced: false)
      return if file.nil?
      if real != path
        file.display = display_path(path, home: home)
        file.resolves_to = display_path(real, home: home)
      end
      out << file
      return unless file.shown? && depth < MAX_DEPTH

      sourced_paths(file, home: home).each do |target|
        collect(target, home: home, sourced_by: file.display, depth: depth + 1, seen: seen, out: out)
      end
    end

    def render(path, home:, sourced_by:, forced:)
      display = display_path(path, home: home)
      size = begin
        ::File.size(path)
      rescue SystemCallError
        return nil
      end
      if !forced && size > MAX_AUTO_BYTES
        return File_.new(display: display, path: path, lines: nil, sourced_by: sourced_by,
                         note: "not shown — #{(size / 1024.0).round}KB, too large to be a hand-maintained startup file. " \
                               "Name it explicitly to read it anyway.")
      end

      # `.scrub` is not defensive tidying. Every rule in this module and in
      # Redact is a regex, and a regex match against invalid UTF-8 raises
      # ArgumentError — so one latin-1 byte in a comment (an accented name in a
      # shell config is all it takes) would crash `dev agent doctor` on that
      # machine, and the doctor is what reports the credentials. Failing closed
      # on the check that finds the leak is the worst available failure, and it
      # would fire on exactly one runner and look like a code bug.
      body = begin
        ::File.read(path, encoding: "UTF-8").scrub("?")
      rescue SystemCallError
        return nil
      end
      lines = body.lines.each_with_index.map { |raw, i| line(raw.chomp, i + 1) }
      File_.new(display: display, path: path, lines: lines, sourced_by: sourced_by, note: nil)
    end

    # The one place a raw line becomes a safe one.
    #
    # Redact runs FIRST and its verdict is kept, because it is the only thing
    # that can say "this IS a credential" rather than "this might be anything".
    # Hiding first would collapse both into `[hidden]` and lose the distinction
    # the doctor reports on.
    def line(raw, number)
      match = ASSIGNMENT.match(raw)
      return Line.new(number: number, text: Redact.command(raw), state: Redact.secret?(raw) ? :redacted : :shown, name: nil) if match.nil?

      prefix, name, value = match[1], match[2], match[3]
      return Line.new(number: number, text: "#{prefix}#{name}=#{Redact::PLACEHOLDER}", state: :redacted, name: name) if Redact.secret?(raw)
      return Line.new(number: number, text: raw, state: :shown, name: name) if structural?(value)

      Line.new(number: number, text: "#{prefix}#{name}=#{HIDDEN}", state: :hidden, name: name)
    end

    # Whether a value may be shown. Default-deny: this returns true only for
    # shapes that are positively recognised as structure.
    def structural?(value)
      unquoted = unquote(value)
      return false if unquoted.nil?
      return true if unquoted.strip.empty?
      unquoted.split(/\s+/).reject(&:empty?).all? { |token| structural_token?(token) }
    end

    def structural_token?(token)
      return true if token.match?(LITERAL) || token.match?(FLAG)

      # A bareword is never shown, however innocent it looks: nothing about the
      # SHAPE of `hunter2` distinguishes it from `vim`. A value earns its way
      # out by being anchored — rooted at `/`, `~` or `.`, or naming a variable.
      return false unless token.include?("$") || token.start_with?("/", "~", "./", "../")

      token.split(":", -1).all? { |part| part.empty? || part.match?(PATH) }
    end

    # Strips ONE matching pair of surrounding quotes. Anything else quoted —
    # a value that opens a quote and closes it mid-line, a mixed quoting — is
    # nil, i.e. not structural, i.e. hidden. There is no shell parser here on
    # purpose; a half-understood one would show what it failed to understand.
    def unquote(value)
      v = value.strip
      return v unless v.start_with?("'", '"')
      quote = v[0]
      return nil unless v.length >= 2 && v.end_with?(quote)
      inner = v[1..-2]
      inner.include?(quote) ? nil : inner
    end

    # ---- sourced files ----

    # The `source` targets of an already-rendered file, resolved statically.
    #
    # Only `~` and `$HOME` are expanded, and anything still holding a `$` or a
    # glob is dropped rather than guessed at. A target outside `$HOME` is
    # dropped too: this command exists to make a HUMAN'S dotfiles safe to read,
    # and following it into `/opt` would turn it into a general file reader
    # nobody reviewed it as.
    def sourced_paths(file, home:)
      file.lines.flat_map { |l| source_targets(l) }.filter_map { |raw| resolve_source(raw, home: home) }
    end

    # The raw `source` arguments on one line, and only on a line that was SHOWN.
    # A hidden or redacted line's text no longer holds its argument, so there is
    # nothing to follow and nothing to report — following one would mean going
    # back to the raw text this module exists to stop handing out.
    def source_targets(line)
      return [] unless line.state == :shown
      line.text.scan(SOURCE).flatten
    end

    def resolve_source(raw, home:)
      target = raw.gsub(/\A["']|["']\z/, "")
      target = target.sub(/\A~/, home).sub(/\A\$\{?HOME\}?/, home)
      return nil if target.include?("$") || target.match?(/[*?\[]/)
      return nil unless target.start_with?("/")
      expanded = ::File.expand_path(target)
      expanded.start_with?("#{home}/") ? expanded : nil
    end

    # The unfollowed `source` targets, for a reader who needs to know the chain
    # does not end where the output does.
    def unresolved_sources(file, home:)
      return [] unless file.shown?
      file.lines.flat_map { |l| source_targets(l) }
          .select { |raw| resolve_source(raw, home: home).nil? }
          .uniq
    end

    def display_path(path, home:)
      path.start_with?("#{home}/") ? "~#{path[home.length..]}" : path
    end
  end
end
