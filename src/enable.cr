require "http/client"
require "json"
require "option_parser"

module Enable
  VERSION = "0.5.1"

  CONFIG_DIR  = Path.home / ".config" / "enable"
  CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"
  CONFIG_FILE = CONFIG_DIR / "config.json"

  struct Credentials
    include JSON::Serializable
    property access_token : String
    property refresh_token : String?
    property email : String?
    property default_company_id : String?

    def initialize(@access_token, @refresh_token = nil, @email = nil, @default_company_id = nil)
    end
  end

  struct AppConfig
    include JSON::Serializable
    property base_url : String = "https://api.enable.io"

    def initialize(@base_url = "https://api.enable.io")
    end
  end

  module Config
    extend self

    def load_config : AppConfig
      # ENABLE_API env var overrides config file
      if env_url = ENV["ENABLE_API"]?
        return AppConfig.new(base_url: env_url)
      end
      if File.exists?(CONFIG_FILE)
        AppConfig.from_json(File.read(CONFIG_FILE))
      else
        AppConfig.new
      end
    end

    def load_credentials : Credentials
      unless File.exists?(CREDENTIALS_FILE)
        STDERR.puts "Not logged in. Run: enbl login"
        exit 1
      end
      Credentials.from_json(File.read(CREDENTIALS_FILE))
    end

    def save_credentials(creds : Credentials)
      Dir.mkdir_p(CONFIG_DIR)
      File.write(CREDENTIALS_FILE, creds.to_json)
      File.chmod(CREDENTIALS_FILE, 0o600)
    end

    def clear_credentials
      File.delete(CREDENTIALS_FILE) if File.exists?(CREDENTIALS_FILE)
    end
  end

  class AuthError < Exception; end

  module API
    extend self

    def get(path : String, params = {} of String => String) : JSON::Any
      request("GET", path, params)
    end

    def patch(path : String, body : String) : JSON::Any
      request("PATCH", path, body: body)
    end

    def post(path : String, body : String? = nil) : JSON::Any
      request("POST", path, body: body)
    end

    private def request(method : String, path : String, params = {} of String => String, body : String? = nil, retried = false) : JSON::Any
      config = Config.load_config
      creds = Config.load_credentials

      uri = URI.parse("#{config.base_url}#{path}")
      unless params.empty?
        query = params.map { |k, v| "#{URI.encode_path(k)}=#{URI.encode_path(v)}" }.join("&")
        uri.query = query
      end

      headers = HTTP::Headers{
        "Authorization" => "Bearer #{creds.access_token}",
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
      }

      response = case method
                 when "GET"    then HTTP::Client.get(uri, headers: headers)
                 when "PATCH"  then HTTP::Client.patch(uri, headers: headers, body: body)
                 when "POST"   then HTTP::Client.post(uri, headers: headers, body: body)
                 when "DELETE" then HTTP::Client.delete(uri, headers: headers)
                 else               raise "Unknown method: #{method}"
                 end

      if response.status_code == 401 && !retried
        if try_refresh
          return request(method, path, params, body, retried: true)
        end
        raise AuthError.new("Session expired. Run: enbl login")
      end

      if response.status_code == 401
        raise AuthError.new("Session expired. Run: enbl login")
      end

      unless response.success?
        STDERR.puts "Error (#{response.status_code}): #{response.body}"
        exit 1
      end

      JSON.parse(response.body)
    end

    private def try_refresh : Bool
      creds = Config.load_credentials
      return false unless rt = creds.refresh_token

      config = Config.load_config
      headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}
      body = {refresh_token: rt}.to_json
      response = HTTP::Client.post("#{config.base_url}/api/cli_auth/refresh", headers: headers, body: body)
      return false unless response.success?

      data = JSON.parse(response.body)
      new_creds = Credentials.new(
        access_token: data["token"].as_s,
        refresh_token: data["refresh_token"]?.try(&.as_s?),
        email: creds.email,
        default_company_id: creds.default_company_id,
      )
      Config.save_credentials(new_creds)
      true
    end
  end

  module Auth
    extend self

    def login
      config = Config.load_config
      headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}

      # Step 1: Create auth session
      response = HTTP::Client.post("#{config.base_url}/api/cli_auth", headers: headers)
      unless response.success?
        STDERR.puts "Failed to start auth (#{response.status_code}): #{response.body}"
        exit 1
      end

      data = JSON.parse(response.body)
      secret = data["secret"].as_s
      authorize_url = data["authorize_url"].as_s
      expires_in = data["expires_in"].as_i

      puts "Opening browser to authorize..."
      puts "  #{authorize_url}"
      puts ""

      {% if flag?(:darwin) %}
        Process.run("open", [authorize_url])
      {% elsif flag?(:linux) %}
        Process.run("xdg-open", [authorize_url])
      {% end %}

      # Step 2: Poll for approval
      puts "Waiting for authorization..."
      deadline = Time.utc + expires_in.seconds
      resolve_url = "#{config.base_url}/api/cli_auth/resolve/#{secret}"

      loop do
        sleep 1.seconds
        break if Time.utc > deadline

        poll = HTTP::Client.get(resolve_url, headers: headers)
        next unless poll.success?

        result = JSON.parse(poll.body)
        case result["code"].as_s
        when "resolved"
          creds = Credentials.new(
            access_token: result["token"].as_s,
            refresh_token: result["refresh_token"]?.try(&.as_s?),
            email: result["email"]?.try(&.as_s),
          )
          Config.save_credentials(creds)
          puts "Authenticated as #{creds.email || "unknown"}."
          return
        when "expired"
          STDERR.puts "Session expired. Run: enbl login"
          exit 1
        end
      end

      STDERR.puts "Authorization timed out. Run: enbl login"
      exit 1
    end

    def logout
      Config.clear_credentials
      puts "Logged out."
    end
  end

  module Output
    extend self

    @@json_mode = false
    @@quiet_mode = false

    def json_mode!
      @@json_mode = true
    end

    def quiet_mode!
      @@quiet_mode = true
    end

    def json_mode? : Bool
      @@json_mode
    end

    def quiet_mode? : Bool
      @@quiet_mode
    end

    def json(data : JSON::Any)
      puts data.to_pretty_json
    end

    def table(headers : Array(String), rows : Array(Array(String)))
      return if rows.empty?

      widths = headers.map_with_index do |h, i|
        ([h.size] + rows.map { |r| (r[i]? || "").size }).max
      end

      # Header
      header_line = headers.map_with_index { |h, i| h.ljust(widths[i]) }.join("  ")
      puts header_line
      puts widths.map { |w| "-" * w }.join("  ")

      # Rows
      rows.each do |row|
        line = row.map_with_index { |cell, i| (cell || "").ljust(widths[i]? || 0) }.join("  ")
        puts line
      end
    end

    def record(pairs : Array(Tuple(String, String)))
      max_key = pairs.map { |k, _| k.size }.max? || 0
      pairs.each do |key, value|
        puts "#{key.rjust(max_key)}: #{value}"
      end
    end
  end

  # ---- Commands ----

  def self.cmd_status
    creds = Config.load_credentials
    data = API.get("/api/v1/companies")
    if Output.json_mode?
      Output.json(data)
    else
      puts "Logged in#{creds.email ? " as #{creds.email}" : ""}"
      puts "Default company: #{creds.default_company_id || "(none)"}"
      companies = data.as_a
      puts "Companies: #{companies.size}"
      companies.each do |c|
        puts "  #{c["name"]} (#{c["id"]})"
      end
    end
  end

  def self.cmd_me(contract_id : String? = nil)
    # Use ENABLE_CONTRACT_ID from env if not provided
    cid = contract_id || ENV["ENABLE_CONTRACT_ID"]?
    params = {} of String => String
    params["contract_id"] = cid if cid
    data = API.get("/api/v1/me", params)
    if Output.json_mode?
      Output.json(data)
    else
      if cid
        Output.record([
          {"Contract", data["contract_id"].as_s[0..7]},
          {"Company", "#{data["company_name"]} (#{data["company_id"].as_s[0..7]})"},
          {"Role", data["role"]?.try(&.as_s) || ""},
          {"Status", data["status"].as_s},
          {"Name", data["name"]?.try(&.as_s) || ""},
          {"Email", data["email"]?.try(&.as_s) || ""},
          {"Manager", data["manager_id"]?.try(&.as_s.try { |s| s[0..7] }) || "(none)"},
        ])
      else
        puts "User: #{data["email"]}"
        companies = data["companies"].as_a
        puts "Companies: #{companies.size}"
        companies.each do |c|
          puts "  #{c["name"]} (#{c["id"]})"
        end
      end
    end
  end

  def self.cmd_companies_list
    data = API.get("/api/v1/companies")
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |c|
        [c["id"].as_s[0..7], c["name"].as_s, c["status"].as_s, c["agent_count"].to_s]
      end
      Output.table(["ID", "NAME", "STATUS", "AGENTS"], rows)
    end
  end

  def self.cmd_companies_show(id : String)
    data = API.get("/api/v1/companies/#{id}")
    if Output.json_mode?
      Output.json(data)
    else
      Output.record([
        {"ID", data["id"].as_s},
        {"Name", data["name"].as_s},
        {"Status", data["status"].as_s},
        {"Mission", data["mission"]?.try(&.as_s) || ""},
        {"Agents", data["agent_count"].to_s},
        {"Created", data["created_at"].as_s[0..9]},
      ])
    end
  end

  def self.resolve_company(company_flag : String?) : String
    if cid = company_flag
      return cid
    end
    # Check ENABLE_COMPANY_ID env var
    if cid = ENV["ENABLE_COMPANY_ID"]?
      return cid
    end
    creds = Config.load_credentials
    if cid = creds.default_company_id
      return cid
    end
    # If user has exactly one company, use it
    data = API.get("/api/v1/companies")
    companies = data.as_a
    if companies.size == 1
      return companies[0]["id"].as_s
    end
    STDERR.puts "Multiple companies found. Use --company or set a default."
    companies.each do |c|
      STDERR.puts "  #{c["name"]}: #{c["id"]}"
    end
    exit 1
  end

  def self.cmd_contracts_list(company_id : String, params = {} of String => String)
    data = API.get("/api/v1/companies/#{company_id}/contracts", params)
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |c|
        profile = c["profile"]?
        [c["id"].as_s[0..7], profile.try { |p| p["name"]?.try(&.as_s) } || "", c["role"]?.try(&.as_s) || "", c["status"].as_s]
      end
      Output.table(["ID", "AGENT", "ROLE", "STATUS"], rows)
    end
  end

  def self.cmd_contracts_show(company_id : String, id : String)
    data = API.get("/api/v1/companies/#{company_id}/contracts/#{id}")
    if Output.json_mode?
      Output.json(data)
    else
      profile = data["profile"]?
      Output.record([
        {"ID", data["id"].as_s},
        {"Agent", profile.try { |p| p["name"]?.try(&.as_s) } || ""},
        {"Role", data["role"]?.try(&.as_s) || ""},
        {"Status", data["status"].as_s},
        {"Rate", "$#{data["hourly_rate"]}/hr"},
        {"Start", data["start_date"]?.try(&.as_s) || ""},
        {"Heartbeat", data["heartbeat_status"]?.try(&.as_s) || ""},
      ])
      if chain = data["chain_of_command"]?.try(&.as_a)
        unless chain.empty?
          puts "\nChain of command:"
          chain.each { |c| puts "  #{c["name"]?.try(&.as_s)} (#{c["role"]?.try(&.as_s)})" }
        end
      end
    end
  end

  def self.cmd_tasks_list(company_id : String, params = {} of String => String)
    data = API.get("/api/v1/companies/#{company_id}/tasks", params)
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |t|
        assignee = t["assignee"]?
        [t["id"].as_s[0..7], t["title"].as_s[0..39], t["status"].as_s, t["priority"].as_s, assignee.try { |a| a["name"]?.try(&.as_s) } || ""]
      end
      Output.table(["ID", "TITLE", "STATUS", "PRIORITY", "ASSIGNEE"], rows)
    end
  end

  def self.cmd_tasks_show(company_id : String, id : String)
    data = API.get("/api/v1/companies/#{company_id}/tasks/#{id}")
    if Output.json_mode?
      Output.json(data)
    else
      assignee = data["assignee"]?
      Output.record([
        {"ID", data["id"].as_s},
        {"Title", data["title"].as_s},
        {"Status", data["status"].as_s},
        {"Priority", data["priority"].as_s},
        {"Assignee", assignee.try { |a| a["name"]?.try(&.as_s) } || "(unassigned)"},
        {"Due", data["due_date"]?.try(&.as_s) || "(none)"},
        {"Created", data["created_at"].as_s[0..9]},
      ])
      if desc = data["description"]?.try(&.as_s)
        puts "\n#{desc}" unless desc.empty?
      end
      if subtasks = data["subtasks"]?.try(&.as_a)
        unless subtasks.empty?
          puts "\nSubtasks:"
          subtasks.each { |s| puts "  [#{s["status"]}] #{s["title"]}" }
        end
      end
    end
  end

  def self.cmd_tasks_create(company_id : String, title : String, description : String? = nil,
                            assignee_id : String? = nil, priority : String? = nil,
                            parent_id : String? = nil, creator_contract_id : String? = nil)
    body = JSON.build do |json|
      json.object do
        json.field "task" do
          json.object do
            json.field "title", title
            json.field "description", description if description
            json.field "assignee_id", assignee_id if assignee_id
            json.field "priority", priority if priority
            json.field "parent_id", parent_id if parent_id
            json.field "creator_contract_id", creator_contract_id if creator_contract_id
          end
        end
      end
    end
    data = API.post("/api/v1/companies/#{company_id}/tasks", body)
    if Output.json_mode?
      Output.json(data)
    else
      puts "Created task #{data["id"].as_s[0..7]}: #{data["title"]}"
    end
  end

  def self.cmd_tasks_update(company_id : String, id : String, updates : Hash(String, String))
    body = JSON.build do |json|
      json.object do
        json.field "task" do
          json.object do
            updates.each { |k, v| json.field k, v }
          end
        end
      end
    end
    data = API.patch("/api/v1/companies/#{company_id}/tasks/#{id}", body)
    if Output.json_mode?
      Output.json(data)
    else
      puts "Updated task #{data["id"].as_s[0..7]}: #{data["title"]}"
    end
  end

  def self.cmd_tasks_comment(company_id : String, id : String, body_text : String, contract_id : String? = nil)
    cid = contract_id || ENV["ENABLE_CONTRACT_ID"]?
    payload = JSON.build do |json|
      json.object do
        json.field "body", body_text
        json.field "contract_id", cid if cid
      end
    end
    data = API.post("/api/v1/companies/#{company_id}/tasks/#{id}/comment", payload)
    if Output.json_mode?
      Output.json(data)
    else
      count = data["comments"]?.try(&.as_a.size) || 0
      puts "Comment added (#{count} total)."
    end
  end

  def self.cmd_approvals_list(company_id : String, params = {} of String => String)
    data = API.get("/api/v1/companies/#{company_id}/approvals", params)
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |a|
        requester = a["requester"]?
        [a["id"].as_s[0..7], a["gate_type"].as_s, a["status"].as_s, requester.try { |r| r["name"]?.try(&.as_s) } || ""]
      end
      Output.table(["ID", "GATE", "STATUS", "REQUESTER"], rows)
    end
  end

  def self.cmd_approvals_show(company_id : String, id : String)
    data = API.get("/api/v1/companies/#{company_id}/approvals/#{id}")
    if Output.json_mode?
      Output.json(data)
    else
      requester = data["requester"]?
      Output.record([
        {"ID", data["id"].as_s},
        {"Gate", data["gate_type"].as_s},
        {"Status", data["status"].as_s},
        {"Requester", requester.try { |r| r["name"]?.try(&.as_s) } || ""},
        {"Created", data["created_at"].as_s[0..9]},
      ])
      if comments = data["comments"]?.try(&.as_a)
        unless comments.empty?
          puts "\nComments:"
          comments.each do |c|
            puts "  [#{c["at"]?.try(&.as_s.try { |s| s[0..9] })}] #{c["author"]}: #{c["body"]}"
          end
        end
      end
    end
  end

  def self.cmd_activity_list(company_id : String, params = {} of String => String)
    data = API.get("/api/v1/companies/#{company_id}/activity", params)
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |e|
        [e["created_at"].as_s[0..15], e["action"].as_s, e["actor_type"]?.try(&.as_s) || ""]
      end
      Output.table(["TIME", "ACTION", "ACTOR"], rows)
    end
  end

  def self.cmd_profiles_list(params = {} of String => String)
    data = API.get("/api/v1/profiles", params)
    if Output.json_mode?
      Output.json(data)
    else
      rows = data.as_a.map do |p|
        [p["id"].as_s[0..7], p["name"].as_s, p["location"]?.try(&.as_s) || "", p["ai_model"]?.try(&.as_s) || ""]
      end
      Output.table(["ID", "NAME", "LOCATION", "MODEL"], rows)
    end
  end

  # ---- Executor ----

  module Executor
    extend self

    def run(task_id : String)
      STDERR.puts "Fetching execution payload for #{task_id[0..7]}..."
      payload = API.get("/api/v1/executions/#{task_id}")

      prompt = payload["prompt"]?.try(&.as_s?)
      unless prompt
        STDERR.puts "No execution prompt — task may not be ready."
        exit 1
      end

      contract_id = payload["contract_id"]?.try(&.as_s?)
      company_id = payload["company_id"]?.try(&.as_s?)
      runtime = payload["runtime"]?.try(&.as_s?) || "claude-code"
      budget = payload.dig?("config", "budget").try(&.as_s?) || "2.00"
      session_id = payload.dig?("config", "session_id").try(&.as_s?)
      title = payload["title"]?.try(&.as_s?) || task_id

      STDERR.puts "Task: #{title}"
      STDERR.puts "Runtime: #{runtime} | Budget: $#{budget}"

      case runtime
      when "claude-code"
        run_claude(task_id, prompt, budget, session_id,
          contract_id: contract_id, company_id: company_id)
      else
        STDERR.puts "Unknown runtime: #{runtime}"
        post_complete(task_id, status: "failed", output: "Unknown runtime: #{runtime}")
        exit 1
      end
    end

    private def run_claude(task_id : String, prompt : String, budget : String, session_id : String?,
                           contract_id : String? = nil, company_id : String? = nil)
      args = ["--print", "--output-format", "json", "--dangerously-skip-permissions", "--max-budget-usd", budget]
      if sid = session_id
        args.push("--resume", sid, "-p", prompt)
      else
        args.push("-p", prompt)
      end

      STDERR.puts "Running: claude #{args[0..5].join(" ")}..."

      # Build env with ENABLE_* vars
      env = {} of String => String
      env["ENABLE_TASK_ID"] = task_id
      env["ENABLE_CONTRACT_ID"] = contract_id if contract_id
      env["ENABLE_COMPANY_ID"] = company_id if company_id
      if api_url = ENV["ENABLE_API"]?
        env["ENABLE_API"] = api_url
      end

      output = IO::Memory.new
      status : Process::Status? = nil

      # Trap signals — always POST completion
      completed = false
      {% for sig in ["INT", "TERM"] %}
        Signal::{{ sig.id }}.trap do
          unless completed
            completed = true
            STDERR.puts "\nCaught SIG{{ sig.id }} — sending failure completion..."
            post_complete(task_id,
              status: "failed",
              output: output.to_s.presence || "Killed by SIG{{ sig.id }}")
          end
          exit 1
        end
      {% end %}

      begin
        status = Process.run("claude", args, output: output, error: STDERR, env: env)
      rescue ex
        unless completed
          completed = true
          post_complete(task_id, status: "failed", output: "Process error: #{ex.message}")
        end
        STDERR.puts "Execution failed: #{ex.message}"
        exit 1
      end

      raw = output.to_s
      completed = true

      if status.try(&.success?)
        # Parse stats from JSON output
        stats = {} of String => JSON::Any
        s_id : String? = nil
        begin
          parsed = JSON.parse(raw)
          s_id = parsed["session_id"]?.try(&.as_s)
          {"total_cost_usd", "duration_ms", "num_turns"}.each do |k|
            if v = parsed[k]?
              stats[k] = v
            end
          end
        rescue
        end

        STDERR.puts "Execution completed. Posting results..."
        post_complete(task_id,
          status: "done",
          output: raw,
          session_id: s_id,
          stats: stats)
        puts raw unless Output.quiet_mode?
      else
        STDERR.puts "Claude exited with #{status.try(&.exit_code) || "unknown"}"
        post_complete(task_id, status: "failed", output: raw.presence || "Non-zero exit")
        exit 1
      end
    end

    def post_complete(task_id : String, status : String, output : String,
                      session_id : String? = nil, stats = {} of String => JSON::Any)
      body = JSON.build do |json|
        json.object do
          json.field "output", output
          json.field "status", status
          json.field "session_id", session_id if session_id
          json.field "stats" do
            json.object do
              stats.each { |k, v| json.field k, v }
            end
          end
        end
      end

      begin
        API.post("/api/v1/executions/#{task_id}/complete", body)
        STDERR.puts "Completion posted (#{status})."
      rescue ex
        STDERR.puts "WARNING: Failed to post completion: #{ex.message}"
      end
    end
  end
end

# ---- Main ----

company_flag : String? = nil
json_flag = false
quiet_flag = false
limit_flag = "25"
verbose_flag = false
command = "help"
remaining_args = [] of String
assignee_flag : String? = nil
status_flag : String? = nil
priority_flag : String? = nil
title_flag : String? = nil
description_flag : String? = nil
parent_flag : String? = nil

OptionParser.parse(ARGV) do |parser|
  parser.on("-c COMPANY", "--company=COMPANY", "Company ID") { |v| company_flag = v }
  parser.on("-j", "--json", "JSON output") { json_flag = true }
  parser.on("-q", "--quiet", "Minimal output") { quiet_flag = true }
  parser.on("-n LIMIT", "--limit=LIMIT", "Max results") { |v| limit_flag = v }
  parser.on("-v", "--verbose", "Verbose output") { verbose_flag = true }
  parser.on("--assignee=ID", "Filter by assignee") { |v| assignee_flag = v }
  parser.on("--status=STATUS", "Filter by status") { |v| status_flag = v }
  parser.on("--priority=PRIORITY", "Filter by priority") { |v| priority_flag = v }
  parser.on("--title=TITLE", "Task title") { |v| title_flag = v }
  parser.on("--description=DESC", "Task description") { |v| description_flag = v }
  parser.on("--parent=ID", "Parent task ID") { |v| parent_flag = v }
  parser.on("--version", "Show version") { puts "enbl #{Enable::VERSION}"; exit 0 }
  parser.on("-h", "--help", "Show help") { command = "help" }
  parser.unknown_args do |args|
    remaining_args = args
  end
end

# First positional arg is the command
command = remaining_args.shift? || command
command = "help" if command == "help"

# Rewrite bare resource names to resource:list
known_resources = %w[companies contracts tasks approvals activity profiles conversations]
if known_resources.includes?(command)
  command = "#{command}:list"
end

Enable::Output.json_mode! if json_flag
Enable::Output.quiet_mode! if quiet_flag

begin
  case command
  when "help"
    puts <<-HELP
    enbl — CLI for the Enable AI workforce platform

    USAGE
      enbl <resource>:<action> [options]
      enbl <resource> [options]          (defaults to :list)

    COMMANDS
      login                  Authenticate via browser (OAuth device flow)
      logout                 Clear stored credentials
      status                 Show current user and companies
      me                     Who am I? (identity + contract info)

      companies              List your companies
      companies:show <id>    Show company details

      contracts              List agents in a company
      contracts:show <id>    Agent contract details

      tasks                  List tasks
      tasks:show <id>        Task details with subtasks
      tasks:create           Create a task (--title, --description, --assignee, --priority)
      tasks:update <id>      Update a task (--title, --status, --assignee, --priority, --description)
      tasks:comment <id>     Add a comment to a task (message as remaining args)

      approvals              List approvals
      approvals:show <id>    Approval details

      activity               Recent activity feed
      profiles               List agent profiles

      execute <task-id>      Execute a task (kubelet-style runner)

    FLAGS
      -c, --company=ID       Company ID (defaults to ENABLE_COMPANY_ID or sole company)
      --json                 JSON output
      -n, --limit=N          Max results (default 25)
      -q, --quiet            Minimal output
      -v, --verbose          Verbose output

    TASK FLAGS
      --title=TITLE          Task title (create/update)
      --description=DESC     Task description (create/update)
      --assignee=ID          Assignee contract ID (filter/create/update)
      --status=STATUS        Task status (filter/update)
      --priority=PRIORITY    Task priority (filter/create/update)
      --parent=ID            Parent task ID (create)

    ENVIRONMENT
      ENABLE_API             Base URL override (e.g. http://localhost:3000)
      ENABLE_CONTRACT_ID     Default contract identity (set by provisioning)
      ENABLE_COMPANY_ID      Default company (set by provisioning)
      ENABLE_TASK_ID         Current task (set by executor)

    EXAMPLES
      enbl me
      enbl tasks --status=todo --assignee=<id>
      enbl tasks:create --title="Fix login bug" --assignee=<id>
      enbl tasks:update <id> --status=done
      enbl tasks:comment <id> Found the root cause in auth.rb
      enbl execute <task-id>
    HELP
  when "login"
    Enable::Auth.login
  when "logout"
    Enable::Auth.logout
  when "status"
    Enable.cmd_status
  when "me"
    contract_id = remaining_args[0]?
    Enable.cmd_me(contract_id)
  when "companies:list"
    Enable.cmd_companies_list
  when "companies:show"
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl companies:show <id>"; exit 1)
    Enable.cmd_companies_show(id)
  when "contracts:list"
    cid = Enable.resolve_company(company_flag)
    params = {"per_page" => limit_flag}
    params["status"] = status_flag.not_nil! if status_flag
    Enable.cmd_contracts_list(cid, params)
  when "contracts:show"
    cid = Enable.resolve_company(company_flag)
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl contracts:show <id>"; exit 1)
    Enable.cmd_contracts_show(cid, id)
  when "tasks:list"
    cid = Enable.resolve_company(company_flag)
    params = {"per_page" => limit_flag}
    params["status"] = status_flag.not_nil! if status_flag
    params["priority"] = priority_flag.not_nil! if priority_flag
    params["assignee"] = assignee_flag.not_nil! if assignee_flag
    Enable.cmd_tasks_list(cid, params)
  when "tasks:show"
    cid = Enable.resolve_company(company_flag)
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl tasks:show <id>"; exit 1)
    Enable.cmd_tasks_show(cid, id)
  when "tasks:create"
    cid = Enable.resolve_company(company_flag)
    t = title_flag
    unless t
      STDERR.puts "Usage: enbl tasks:create --title=\"...\""
      exit 1
    end
    creator_cid = ENV["ENABLE_CONTRACT_ID"]?
    Enable.cmd_tasks_create(cid, t,
      description: description_flag,
      assignee_id: assignee_flag,
      priority: priority_flag,
      parent_id: parent_flag,
      creator_contract_id: creator_cid)
  when "tasks:update"
    cid = Enable.resolve_company(company_flag)
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl tasks:update <id> [--status=X --title=X ...]"; exit 1)
    updates = {} of String => String
    updates["title"] = title_flag.not_nil! if title_flag
    updates["description"] = description_flag.not_nil! if description_flag
    updates["status"] = status_flag.not_nil! if status_flag
    updates["priority"] = priority_flag.not_nil! if priority_flag
    updates["assignee_id"] = assignee_flag.not_nil! if assignee_flag
    if updates.empty?
      STDERR.puts "Nothing to update. Use --status, --title, --description, --priority, or --assignee."
      exit 1
    end
    Enable.cmd_tasks_update(cid, id, updates)
  when "tasks:comment"
    cid = Enable.resolve_company(company_flag)
    id = remaining_args.shift? || (STDERR.puts "Usage: enbl tasks:comment <id> <message>"; exit 1)
    body = remaining_args.join(" ")
    if body.empty?
      STDERR.puts "Usage: enbl tasks:comment <id> <message>"
      exit 1
    end
    Enable.cmd_tasks_comment(cid, id, body)
  when "approvals:list"
    cid = Enable.resolve_company(company_flag)
    params = {"per_page" => limit_flag}
    params["status"] = status_flag.not_nil! if status_flag
    Enable.cmd_approvals_list(cid, params)
  when "approvals:show"
    cid = Enable.resolve_company(company_flag)
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl approvals:show <id>"; exit 1)
    Enable.cmd_approvals_show(cid, id)
  when "activity:list"
    cid = Enable.resolve_company(company_flag)
    Enable.cmd_activity_list(cid, {"per_page" => limit_flag})
  when "profiles:list"
    Enable.cmd_profiles_list({"per_page" => limit_flag})
  when "execute"
    id = remaining_args[0]? || (STDERR.puts "Usage: enbl execute <task-id>"; exit 1)
    Enable::Executor.run(id)
  else
    STDERR.puts "Unknown command: #{command}. Run: enbl --help"
    exit 1
  end
rescue ex : Enable::AuthError
  STDERR.puts ex.message
  exit 1
end
