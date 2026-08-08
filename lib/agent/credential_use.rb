require 'time'

require 'agent/credentials'
require 'agent/paths'
require 'agent/redact'

# One credential, put into ONE child process, for exactly as long as that process
# runs — and into nothing else (ISS-1037).
#
# WHY THIS EXISTS. ISS-570 handed every session every credential the fleet holds,
# as ordinary environment variables, for the whole life of the session. That was
# the right fix for the problem it had (ISS-565 lost a run to a key that was on
# the machine and never passed down), and it is a bigger grant than any run
# needs: measured on a runner while writing this, 16 of 604 processes carried
# `PLAYBOOK_CLAUDE_KEY` in an environment `ps -Eax` hands to any process of the
# same uid, and 16 carried `NEWRELIC_USER_KEY`. Two of seventeen playbooks use
# either one.
#
# WHAT THIS IS NOT, and the distinction is the whole honesty of ISS-1037. This is
# NOT an access control and nothing on this runner can be one. Every session runs
# as the same uid, so a session that wants a credential can run this command, and
# the env repo the values come from sits unlocked on disk beside the devops
# checkout where any session can read it directly. What it changes is how many
# runs hold a fleet credential when they were never going to use one — from all
# of them, always, to the ones that ask, while they ask.
#
# That is worth the machinery because the exposure that has actually happened
# twice is ACCIDENTAL: ISS-961 captured two siblings' keys with a routine
# `pgrep -fl`, and ISS-1035 captured a human's with a routine read of a shell
# dotfile. Neither session was trying to. A credential that is not in the
# environment cannot be swept up by a process listing, cannot be inherited by a
# dev server that then holds it for hours, and cannot reach a transcript by
# accident — and a transcript, a PR and an issue comment are the durable
# artifacts that make a leak permanent.
#
# WHY EXEC AND NOT PRINT. A command that prints a secret to stdout puts it in the
# session's transcript, which is the one place it must never be — so this never
# has a value in its own output. It resolves, records the use, and `exec`s: the
# value exists only in the environment of the process that replaces this one.
module Agent
  module CredentialUse
    # Refused before anything resolves. Carries the whole message because every
    # refusal here has to teach the correct invocation — a session that gets
    # "no" and no shape retries by inlining the value, which is the ISS-961
    # hazard this is trying to remove.
    Refusal = Class.new(StandardError)

    module_function

    # Never returns: replaces this process with `argv`, whose environment is this
    # process's plus the one credential.
    #
    # `issue` is the run this use is recorded against, and it comes from the
    # environment the EXECUTOR set, exactly as `dev agent run-op`'s does. Unset
    # outside a session, where there is no log tree to write into and the command
    # is simply a convenience — the record is an audit trail for autonomous runs,
    # not a precondition for using a key on a laptop.
    def exec(name:, argv:, issue: ENV["DEV_AGENT_ISSUE"], env: ENV, implicit: false)
      credential, value = resolve!(name, argv, env: env, implicit: implicit)
      record(issue: issue, name: credential.name, argv: argv)
      Process.exec({ credential.name => value }, *argv)
    end

    # `[credential, value]`, or a Refusal explaining what to type instead. Split
    # out from `exec` so every refusal is testable without a process replacement
    # in the middle of it — and so the ONE place a value is returned is a method
    # whose two callers (this command, and its test) both know not to print it.
    def resolve!(name, argv, env: ENV, implicit: false)
      credential = Agent::Credentials.find(name)
      raise Refusal, unknown_message(name) if credential.nil?
      raise Refusal, "name the command to run after a bare `--`." if Array(argv).empty?
      raise Refusal, unreferenced_message(credential) unless implicit || references?(credential, argv)

      status, value, source = Agent::Credentials.probe(credential, env: env)
      unless status == :present
        found = Agent::Credentials::Found.new(credential: credential, status: status, source: source)
        raise Refusal, absent_message(found)
      end
      [credential, value]
    end

    # Whether the command actually names the variable it is asking for.
    #
    # This is a guard against ONE silent failure, and it is the failure this
    # command's shape invites. The correct invocation carries the reference
    # through to an inner shell in SINGLE quotes:
    #
    #     dev agent credential exec --name NEWRELIC_USER_KEY -- \
    #       /bin/zsh -c 'curl ... -H "API-Key: $NEWRELIC_USER_KEY" ...'
    #
    # Write that with double quotes and the OUTER shell expands `$NEWRELIC_USER_KEY`
    # before this command ever starts — to the empty string, because the whole
    # point of ISS-1037 is that it is not in the session's environment. The
    # request then goes out unauthenticated, and NerdGraph answers an empty result
    # set rather than a 401, which reads exactly like a healthy graph. That is
    # ISS-635's failure mode arriving by a new route, and a session would spend
    # the run explaining a production graph that was never queried.
    #
    # An expanded reference leaves no trace, so the detector is the absence of the
    # NAME anywhere in argv. `--implicit` is the escape for a program that reads
    # the variable itself without naming it on its command line.
    def references?(credential, argv) = Array(argv).any? { |word| word.to_s.include?(credential.name) }

    # One line per use, beside the session log rather than under the workspace,
    # for the reason `Agent::Paths.ops_dir` gives: the reap deletes the workspace
    # and an audit trail must outlive what it audits.
    #
    # REDACTED through the same module `Agent::Processes` parses `ps` with. This
    # writes a command line a session composed, and a session that inlined a
    # DIFFERENT secret into it — a database URL, a `gh` token — would otherwise
    # have this command helpfully write it to a file. Best-effort: an audit line
    # that cannot be written must not cost the operation it was recording.
    def record(issue:, name:, argv:)
      number = issue.to_s
      return nil unless number.match?(/\A\d+\z/)

      line = "#{Time.now.utc.iso8601} #{name} #{Agent::Redact.command(Array(argv).join(' '))}"
      Agent::Paths.append_log(Agent::Paths.credential_log(number.to_i), line)
      line
    rescue SystemCallError, IOError
      nil
    end

    def unknown_message(name)
      "unknown credential #{name.to_s.inspect}. This runner knows: " \
        "#{Agent::Credentials::NAMES.join(', ')}."
    end

    def absent_message(found)
      "#{found.name} does not resolve on this runner — #{found.explanation}.\n" \
        "  Needed for #{found.credential.required_by}.\n" \
        "  To provide it: #{found.credential.how_to_provide}.\n" \
        "  Until then this cannot be verified here — do the offline work, say so in the PR, " \
        "and file it with `dev issues workaround`."
    end

    def unreferenced_message(credential)
      "the command never mentions $#{credential.name}, so it would run without it.\n" \
        "  This almost always means the OUTER shell expanded the reference to nothing before " \
        "`dev` started — the value is deliberately NOT in your environment (ISS-1037).\n" \
        "  Use SINGLE quotes so the inner shell is the one that expands it:\n" \
        "      dev agent credential exec --name #{credential.name} -- \\\n" \
        "        /bin/zsh -c '#{credential.usage_example}'\n" \
        "  If the program reads #{credential.name} from its own environment and never names it " \
        "on a command line, pass --implicit."
    end
  end
end
