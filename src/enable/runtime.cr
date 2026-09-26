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
    # How long one printed line of a running run may be.
    LINE = 160
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
        # stream-json prints each event as it happens, so a watcher sees the run while it works.
        # Its last event is the object --output-format json printed, and that is what is posted.
        args = ["claude", "--print", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions", "--max-budget-usd", budget]
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
      # claude-code streams its events; Rails reads the result event, as it read the one object
      # before. A run that never reached it posts all it printed.
      output = (result_line(stdout) if runtime == "claude-code" && events.size > 1) || stdout
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

    # The lines to show for one line a CLI printed, while the run works: claude-code's events in
    # words, the other CLIs' lines as they are. Secrets are hidden, and each line is short.
    def describe(runtime : String, line : String, secrets : Enumerable(String) = [] of String) : Array(String)
      text = line.strip
      return [] of String if text.empty?
      lines = runtime == "claude-code" ? claude_lines(text) : [text]
      lines.compact_map { |l| short(redact(l, secrets)).presence }
    end

    private def claude_lines(text : String) : Array(String)
      event = object(text)
      return [text] unless event
      case event["type"]?.try(&.as_s?)
      when "system"
        event["subtype"]? == "init" ? ["Session started (#{event["model"]? || "unknown model"})"] : [] of String
      when "assistant"
        content(event).compact_map do |part|
          case part["type"]?.try(&.as_s?)
          when "text"     then part["text"]?.try(&.as_s?)
          when "tool_use" then "→ #{part["name"]? || "tool"}: #{tool_summary(part["input"]?)}"
          end
        end
      when "user"
        content(event).compact_map do |part|
          next unless part["type"]? == "tool_result"
          body = result_text(part["content"]?)
          part["is_error"]? == true ? "← error: #{body}" : "← #{body}"
        end
      when "result"
        seconds = event["duration_ms"]?.try(&.as_i64?).try { |ms| (ms / 1000.0).round(1) }
        ["Finished: #{event["num_turns"]?} turns, $#{event["total_cost_usd"]?}, #{seconds}s"]
      else
        [] of String
      end
    end

    private def content(event : JSON::Any) : Array(JSON::Any)
      event.dig?("message", "content").try(&.as_a?) || [] of JSON::Any
    end

    # A tool call in a few words: its description, else its command or path, else its first value.
    private def tool_summary(input : JSON::Any?) : String
      hash = input.try(&.as_h?)
      return "" unless hash
      value = %w[description command file_path path pattern url].compact_map { |k| hash[k]?.try(&.as_s?) }.first? ||
              hash.values.compact_map(&.as_s?).first?
      value.to_s.lines.first? || ""
    end

    # The first line of what a tool returned: a string, or a list of text parts.
    private def result_text(content : JSON::Any?) : String
      text = content.try(&.as_s?) ||
             content.try(&.as_a?).try(&.compact_map { |p| p["text"]?.try(&.as_s?) }.join(" ")) || ""
      text.lines.first? || ""
    end

    private def short(text : String) : String
      one = text.gsub(/\s+/, " ").strip
      one.size > LINE ? "#{one[0, LINE - 1]}…" : one
    end

    # The last line that is claude-code's result event, as it was printed.
    private def result_line(text : String) : String?
      text.lines.reverse.find { |l| object(l).try(&.["type"]?) == "result" }.try(&.strip)
    end

    private def object(text : String) : JSON::Any?
      parsed = JSON.parse(text)
      parsed if parsed.as_h?
    rescue JSON::ParseException
      nil
    end
  end
end
