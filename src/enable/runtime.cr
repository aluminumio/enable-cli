require "json"

module Enable
  # The coding CLIs `enbl execute` can run, what to start for each, and how to read
  # what it printed. The argv and env match the enable_fleet gem's EnableFleet::Cli
  # adapters, so Enable and enbl agree. Pure data-in / data-out: nothing here runs.
  #
  # Enable sets each CLI's home (CLAUDE_CONFIG_DIR, CODEX_HOME, XDG_CONFIG_HOME,
  # GROK_HOME, HOME) and its key (from a 0600 env file) before it starts enbl. The
  # child inherits them unchanged. A key never goes on a command line: the runner is
  # shared, and every Unix user on it can read `ps`.
  module Runtime
    extend self

    NAMES = %w[claude-code codex cursor grok agy]
    STATS = %w[total_cost_usd duration_ms num_turns]
    # What looks like a key or token, for keys enbl does not know by name. Codex
    # prints a rejected key in its 401 message ("Incorrect API key provided: sk-...").
    TOKEN = /\b(?:sk-[\w-]{8,}|xai-[\w-]{8,}|key_[\w-]{8,}|AIza[\w-]{20,}|ya29\.[\w.-]+|eyJ[\w-]+\.[\w.-]+)/

    # The end of one run, as `POST /api/v1/executions/:id/complete` takes it.
    record Result, status : String, output : String, session_id : String?, stats : Hash(String, JSON::Any)

    # The command line for +runtime+. The prompt is an argument of its own, never
    # shell text.
    def argv(runtime : String, prompt : String, budget : String = "2.00",
             session_id : String? = nil, model : String? = nil) : Array(String)
      model_flag = model.presence
      case runtime
      when "claude-code"
        args = ["claude", "--print", "--output-format", "json", "--dangerously-skip-permissions", "--max-budget-usd", budget]
        args.push("--resume", session_id) if session_id
        args.push("-p", prompt)
      when "codex"
        args = ["codex", "exec", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "--json"]
        args.push("-m", model_flag) if model_flag
        args.push(prompt)
      when "cursor"
        args = ["cursor-agent", "-p", "--output-format", "json", "--force", "--trust"]
        args.push("--model", model_flag) if model_flag
        args.push(prompt)
      when "grok"
        args = ["grok", "-p", prompt, "--output-format", "json", "--always-approve"]
        args.push("--model", model_flag) if model_flag
      when "agy"
        args = ["agy", "-p", prompt, "--output-format", "json", "--dangerously-skip-permissions"]
        args.push("--model", model_flag) if model_flag
      else
        raise ArgumentError.new("Unknown runtime: #{runtime}")
      end
      args
    end

    # The env enbl adds for the child. Process.run keeps the rest of enbl's own env,
    # so the home and key that Enable set reach the CLI unchanged.
    def env(runtime : String, task_id : String, contract_id : String? = nil,
            company_id : String? = nil) : Hash(String, String)
      env = {"ENABLE_TASK_ID" => task_id}
      env["ENABLE_CONTRACT_ID"] = contract_id if contract_id
      env["ENABLE_COMPANY_ID"] = company_id if company_id
      # The gem's agy adapter turns this off, so a run does not update the CLI under it.
      env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true" if runtime == "agy"
      env
    end

    # The values to hide from anything enbl posts: every key and token in +env+.
    def secrets(env = ENV) : Array(String)
      env.compact_map { |k, v| v if k.matches?(/(?:KEY|TOKEN|SECRET)\z/) && v.size >= 8 }
    end

    def redact(text : String, secrets : Enumerable(String)) : String
      secrets.reduce(text) { |text_so_far, s| text_so_far.gsub(s, "[hidden]") }.gsub(TOKEN, "[hidden]")
    end

    # Read one run. +stdout+ is posted as the output (Rails reads a JSON object with
    # is_error: true as a failure). The end of +stderr+ stands in for a failed run
    # that printed nothing on stdout.
    def result(runtime : String, stdout : String, exit_code : Int32?, stderr : String = "",
               secrets : Enumerable(String) = [] of String) : Result
      events = events(stdout)
      failed = exit_code != 0 || error?(runtime, events, exit_code)
      output = stdout
      if failed && output.blank?
        output = stderr.lines.last(20).join.presence || "#{runtime} exited with #{exit_code || "unknown"} and printed nothing"
      end
      # Only claude-code resumes today, so only its session id is sent.
      session_id = events.last?.try { |e| e["session_id"]?.try(&.as_s?) } if runtime == "claude-code"
      Result.new(failed ? "failed" : "done", redact(output, secrets), session_id, stats(events))
    end

    # Whether the CLI says the run failed although it may have exited 0.
    def error?(runtime : String, events : Array(JSON::Any), exit_code : Int32?) : Bool
      case runtime
      when "codex"
        # --json prints one event per line; the run failed when its turn did.
        turn = events.reverse.find { |e| e["type"]?.try(&.as_s?).try(&.starts_with?("turn.")) }
        turn.try(&.["type"]) == "turn.failed"
      when "cursor"
        events.last?.try(&.["is_error"]?) == true
      when "grok"
        events.any? { |e| e["type"]? == "error" }
      when "agy"
        exit_code == 3 || events.any? { |e| e["status"]? == "ERROR" }
      else
        # claude-code: unchanged, Rails reads is_error from the output.
        false
      end
    end

    # total_cost_usd, duration_ms and num_turns where the CLI reports them; the last
    # event that has one wins. agy reports duration_seconds.
    def stats(events : Array(JSON::Any)) : Hash(String, JSON::Any)
      stats = {} of String => JSON::Any
      events.each do |e|
        STATS.each { |k| stats[k] = e[k] if e[k]? }
        if !e["duration_ms"]? && (secs = e["duration_seconds"]?) && (n = secs.as_f? || secs.as_i64?.try(&.to_f))
          stats["duration_ms"] = JSON::Any.new((n * 1000).round.to_i64)
        end
      end
      stats
    end

    # The JSON objects in +text+: the whole text when it is one object (claude-code,
    # cursor), else each line that is one (codex, grok and agy print events or logs).
    def events(text : String) : Array(JSON::Any)
      whole = object(text)
      return [whole] if whole
      text.each_line.compact_map { |line| object(line) }.to_a
    end

    private def object(text : String) : JSON::Any?
      parsed = JSON.parse(text)
      parsed if parsed.as_h?
    rescue JSON::ParseException
      nil
    end
  end
end
