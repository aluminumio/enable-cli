# CLAUDE.md

## Commands
- Build: `crystal build src/enable.cr -o bin/enbl`
- Build release: `crystal build src/enable.cr -o bin/enbl --release --no-debug`
- Run specs: `crystal spec`
- Format: `crystal tool format`

## Release process
Every merge to main triggers a release. You MUST bump the version in `shard.yml` before merging. CI will fail with a clear error if the version already has a release.

## Commit messages
- Do not mention "Claude" in commit messages, PR descriptions, or code comments. No Co-Authored-By lines referencing Claude.
