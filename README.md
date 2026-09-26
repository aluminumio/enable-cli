# enbl

Command-line interface for the [Enable](https://app.enable.io) AI workforce platform. Provides human and machine-readable (JSON) access to companies, contracts, tasks, approvals, activity, and profiles.

## Install

```
brew tap aluminumio/tap
brew install enbl
```

Or download prebuilt binaries from [Releases](https://github.com/aluminumio/enable-cli/releases).

## Usage

```
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
```

## Execute runtimes

`enbl execute <task-id>` runs the CLI that the task's `runtime` names, then posts
`{output, status, session_id?, stats}` to `POST /api/v1/executions/:id/complete`
exactly once, also on SIGINT and SIGTERM. `enbl version` lists the runtimes.

| runtime | command | failed when |
|---|---|---|
| `claude-code` | `claude --print --output-format json ...` | non-zero exit (Enable reads `is_error`) |
| `codex` | `codex exec --json ...` | non-zero exit, or the last turn event is `turn.failed` |
| `cursor` | `cursor-agent -p --output-format json ...` | non-zero exit, or `is_error: true` |
| `grok` | `grok -p ... --output-format json` | non-zero exit, or a `"type":"error"` line |
| `agy` | `agy -p ... --output-format json` | non-zero exit (3 included), or `"status":"ERROR"` |

Enable sets each CLI's home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`,
`GROK_HOME`, `HOME`) and key in the environment; the CLI inherits them. No key goes on
a command line, and every `*KEY`, `*TOKEN` and `*SECRET` value is removed from the
output before it is posted.

## Authentication

`enbl login` starts an OAuth device flow: it opens your browser to authorize, then polls until you approve. The CLI stores the resulting token locally.

`enbl logout` removes stored credentials.

## Configuration

- `~/.config/enable/credentials.json` — OAuth token (stored chmod 600)
- `~/.config/enable/config.json` — optional; set `base_url` to point at a different server

## Examples

```bash
# Log in
enbl login

# List in-progress tasks
enbl tasks --status=in_progress

# Show a single task as JSON
enbl tasks:show <id> --json

# List contracts for a specific company
enbl contracts -c <company-id>

# Pipe JSON to jq for filtering
enbl tasks --json | jq '.[] | select(.priority == "urgent")'

# Check who you're logged in as
enbl status
```

## Development

Requires [Crystal](https://crystal-lang.org) >= 1.11.0.

```bash
crystal build src/enable.cr -o bin/enbl    # dev build
make release                                # optimized build
```

## License

MIT
