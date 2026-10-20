# CI Local

macOS menu-bar app that runs free self-hosted GitHub Actions runners on this Mac while GitHub-hosted minutes are billing-blocked.

- Starts/stops one runner per private repo (label `mac-local`), and starts them at login.
- **Runs**: tells apart why a run failed, from its job annotations:
  - billing: GitHub never started the job. Re-running cannot help, so it is never re-run.
  - runner lost: the Mac slept or went offline. Re-run automatically once the runner is back.
  - code: a real failure.
- **Workflows → Make Mac-safe (open PR)**: switches hosted `ubuntu-*` runners to `[self-hosted, mac-local]`, makes GNU `sed -i` portable, and deletes `.env` after jobs that write it (the Mac workspace persists between runs). Anything it cannot fix (apt, service containers, matrix OS, GNU-only flags, deploys with secrets) is listed as a warning in the PR.
- **Local check**: runs `npm run check` in a local clone and installs a pre-push hook.

## Build

```sh
swift test      # unit tests
./build.sh      # builds and installs ~/Applications/CI Local.app
```

Quitting the app stops the runners. Reinstall only when no job is running.

Config: `~/Library/Application Support/CI Local/config.json`. Logs: `~/Library/Logs/CI Local/`. Requires `gh` (authenticated).
