require "http/client"
require "json"
require "option_parser"

module Enable
  VERSION = "0.1.0"

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
        refresh_token: data["refresh_token"]?.try(&.as_s),
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
            refresh_token: result["refresh_token"]?.try(&.as_s),
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

OptionParser.parse(ARGV) do |parser|
  parser.on("-c COMPANY", "--company=COMPANY", "Company ID") { |v| company_flag = v }
  parser.on("--json", "JSON output") { json_flag = true }
  parser.on("-q", "--quiet", "Minimal output") { quiet_flag = true }
  parser.on("-n LIMIT", "--limit=LIMIT", "Max results") { |v| limit_flag = v }
  parser.on("-v", "--verbose", "Verbose output") { verbose_flag = true }
  parser.on("--assignee=ID", "Filter by assignee") { |v| assignee_flag = v }
  parser.on("--status=STATUS", "Filter by status") { |v| status_flag = v }
  parser.on("--priority=PRIORITY", "Filter by priority") { |v| priority_flag = v }
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

      companies              List your companies
      companies:show <id>    Show company details

      contracts              List agents in a company
      contracts:show <id>    Agent contract details

      tasks                  List tasks
      tasks:show <id>        Task details with subtasks

      approvals              List approvals
      approvals:show <id>    Approval details

      activity               Recent activity feed
      profiles               List agent profiles

    FLAGS
      -c, --company=ID       Company ID (defaults to sole/primary company)
      --json                 JSON output
      -n, --limit=N          Max results (default 25)
      -q, --quiet            Minimal output
      -v, --verbose          Verbose output

    TASK FILTERS
      --assignee=ID          Filter by assignee contract ID
      --status=STATUS        Filter by status
      --priority=PRIORITY    Filter by priority

    EXAMPLES
      enbl login
      enbl tasks --status=in_progress --assignee=<id>
      enbl tasks:show <id> --json
      enbl contracts -c <company-id>
    HELP
  when "login"
    Enable::Auth.login
  when "logout"
    Enable::Auth.logout
  when "status"
    Enable.cmd_status
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
  else
    STDERR.puts "Unknown command: #{command}. Run: enbl --help"
    exit 1
  end
rescue ex : Enable::AuthError
  STDERR.puts ex.message
  exit 1
end
