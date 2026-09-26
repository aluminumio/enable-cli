require "spec"
require "../src/enable/runtime"

# The *_bad_key and grok_no_login fixtures were captured from the real CLIs on a Linux
# host with no sign-in (aluminumio/enable-fleet-gem, spec/fixtures/cli). The *_ok and
# cursor_error fixtures follow each CLI's documented JSON output; no sign-in made them.
def fixture(name)
  File.read(Path[__DIR__, "fixtures", name])
end

alias Runtime = Enable::Runtime

describe Enable::Runtime do
  describe ".argv" do
    it "keeps claude-code as it was, with the prompt last" do
      Runtime.argv("claude-code", "do it", "2.00").should eq(
        ["claude", "--print", "--output-format", "json", "--dangerously-skip-permissions", "--max-budget-usd", "2.00", "-p", "do it"])
      Runtime.argv("claude-code", "do it", "1.50", "sess-1").should eq(
        ["claude", "--print", "--output-format", "json", "--dangerously-skip-permissions", "--max-budget-usd", "1.50",
         "--resume", "sess-1", "-p", "do it"])
    end

    it "runs codex exec with --json and the prompt last" do
      Runtime.argv("codex", "do it").should eq(
        ["codex", "exec", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "--json", "do it"])
      Runtime.argv("codex", "do it", model: "gpt-5").should eq(
        ["codex", "exec", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "--json", "-m", "gpt-5", "do it"])
    end

    it "runs cursor-agent headless with the prompt last" do
      Runtime.argv("cursor", "do it").should eq(["cursor-agent", "-p", "--output-format", "json", "--force", "--trust", "do it"])
      Runtime.argv("cursor", "do it", model: "m").last(3).should eq(["--model", "m", "do it"])
    end

    it "runs grok and agy with the prompt after -p" do
      Runtime.argv("grok", "do it").should eq(["grok", "-p", "do it", "--output-format", "json", "--always-approve"])
      Runtime.argv("agy", "do it", model: "g").should eq(
        ["agy", "-p", "do it", "--output-format", "json", "--dangerously-skip-permissions", "--model", "g"])
    end

    it "ignores a session id and an empty model for the other runtimes" do
      Runtime.argv("codex", "x", session_id: "s", model: "").should_not contain("s")
      Runtime.argv("grok", "x", model: "").should_not contain("--model")
    end

    it "refuses an unknown runtime" do
      expect_raises(ArgumentError, "Unknown runtime: gemini") { Runtime.argv("gemini", "x") }
    end

    it "never puts a key from the environment on the command line" do
      Runtime::NAMES.each do |name|
        Runtime.argv(name, "x", "2.00", nil, "m").join(" ").should_not match(/KEY|TOKEN|sk-/)
      end
    end
  end

  describe ".env" do
    it "adds only the ENABLE_* identity, and leaves each CLI's home and key to the inherited env" do
      Runtime.env("codex", "t1", "c1", "co1").should eq(
        {"ENABLE_TASK_ID" => "t1", "ENABLE_CONTRACT_ID" => "c1", "ENABLE_COMPANY_ID" => "co1"})
      Runtime.env("cursor", "t1").keys.should eq(["ENABLE_TASK_ID"])
    end

    it "turns off agy's self-update, as the gem's adapter does" do
      Runtime.env("agy", "t1")["AGY_CLI_DISABLE_AUTO_UPDATE"].should eq("true")
    end
  end

  describe ".secrets and .redact" do
    it "finds every key and token in the environment" do
      env = {"CODEX_API_KEY" => "sk-proj-fixture0000", "GROK_HOME" => "/tmp/grok-abc123", "ENABLE_TOKEN" => "tok-12345678", "SHORT_KEY" => "abc"}
      Runtime.secrets(env).sort.should eq(["sk-proj-fixture0000", "tok-12345678"])
    end

    it "hides a known secret and anything shaped like a key" do
      Runtime.redact("key abcdefgh99 and sk-other-12345678 and xai-abcdefgh1", ["abcdefgh99"]).should eq(
        "key [hidden] and [hidden] and [hidden]")
    end
  end

  describe ".result" do
    it "reads claude-code as before: its session id and stats" do
      r = Runtime.result("claude-code", fixture("claude_ok.json"), 0)
      r.status.should eq("done")
      r.output.should eq(fixture("claude_ok.json"))
      r.session_id.should eq("0b3c2c55-5f7e-4a44-9d51-2f5d0c7f1a11")
      r.stats.should eq({"total_cost_usd" => JSON::Any.new(0.0421), "duration_ms" => JSON::Any.new(4210_i64), "num_turns" => JSON::Any.new(3_i64)})
    end

    it "reads a codex run whose turn completed as done, with no stats or session" do
      r = Runtime.result("codex", fixture("codex_ok.jsonl"), 0)
      r.status.should eq("done")
      r.output.should eq(fixture("codex_ok.jsonl"))
      r.session_id.should be_nil
      r.stats.should be_empty
    end

    it "fails a codex run whose last turn failed, and hides the key codex echoed" do
      jsonl = fixture("codex_bad_key.jsonl")
      r = Runtime.result("codex", jsonl, 0, secrets: ["sk-proj-fixture0000"])
      r.status.should eq("failed")
      r.output.should_not contain("sk-proj-fixture0000")
      r.output.should contain("Incorrect API key provided: [hidden]")
      # Even a key enbl did not know by name is hidden.
      Runtime.result("codex", jsonl, 1).output.should_not contain("sk-proj-fixture0000")
    end

    it "reads cursor's result object: is_error and duration_ms" do
      ok = Runtime.result("cursor", fixture("cursor_ok.json"), 0)
      ok.status.should eq("done")
      ok.stats.should eq({"duration_ms" => JSON::Any.new(5120_i64)})
      ok.session_id.should be_nil
      Runtime.result("cursor", fixture("cursor_error.json"), 0).status.should eq("failed")
    end

    it "fails a grok run with an error event, even at exit 0" do
      Runtime.result("grok", fixture("grok_no_login.jsonl"), 0).status.should eq("failed")
      ok = Runtime.result("grok", fixture("grok_ok.jsonl"), 0)
      ok.status.should eq("done")
      ok.stats.should eq({"num_turns" => JSON::Any.new(2_i64), "duration_ms" => JSON::Any.new(6400_i64)})
    end

    it "reads agy's status, exit code 3, and duration_seconds" do
      ok = Runtime.result("agy", fixture("agy_ok.json"), 0)
      ok.status.should eq("done")
      ok.stats.should eq({"num_turns" => JSON::Any.new(2_i64), "duration_ms" => JSON::Any.new(7500_i64)})
      Runtime.result("agy", fixture("agy_bad_key.txt"), 0).status.should eq("failed")
      Runtime.result("agy", fixture("agy_ok.json"), 3).status.should eq("failed")
    end

    it "fails any runtime on a non-zero exit, and says why from stderr when stdout is empty" do
      r = Runtime.result("cursor", "", 1, "Error: Authentication required. Please run 'agent login' first.\n")
      r.status.should eq("failed")
      r.output.should contain("Authentication required")
      Runtime.result("grok", "", nil).output.should eq("grok exited with unknown and printed nothing")
    end
  end
end
