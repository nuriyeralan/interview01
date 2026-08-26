# Pipeline Orchestrator — Candidate Kit

You are building an **orchestrator** for a fleet of mock Azure DevOps Pipeline agents.
Read [docs/CANDIDATE.md](docs/CANDIDATE.md) first (the brief and how you are graded), then
[docs/API.md](docs/API.md) (the REST surface you call).

## Pick your platform

Each folder holds a self-contained simulator (no runtime install needed) plus the runner(s):

| Folder | Binary | Runner(s) |
| --- | --- | --- |
| `windows-x64/` | `MockAdo.Server.exe` | `run-interview.ps1` |
| `linux-x64/` | `MockAdo.Server` | `run-interview.sh` (or `run-interview.ps1` via `pwsh`) |
| `macos-x64/` | `MockAdo.Server` | `run-interview.sh` (or `run-interview.ps1` via `pwsh`) |
| `macos-arm64/` | `MockAdo.Server` | `run-interview.sh` (or `run-interview.ps1` via `pwsh`) |

`docs/` (shared): your brief, the API reference, and a one-slide architecture diagram.
Only the folders that were published are present.

## Quick start

1. Build and start **your** orchestrator. It must accept pushed requests at
   `POST {your-url}/requests` (respond fast, e.g. `202`) and call the mock ADO REST API to
   schedule work. Any language/stack. Default expected URL is `http://localhost:5090`.

2. From your platform's folder, run the evaluation against your orchestrator (re-run freely):

   **Windows (PowerShell):**
   ```powershell
   cd windows-x64
   .\run-interview.ps1                                  # the practice ladder, in order
   .\run-interview.ps1 -Scenarios warmup-01,smoke-01    # pick specific scenarios
   ```

   **Linux / macOS (bash):**
   ```bash
   cd linux-x64        # or macos-x64 / macos-arm64
   ./run-interview.sh                                   # the practice ladder, in order
   ./run-interview.sh warmup-01,smoke-01                # pick specific scenarios
   ```
   (PowerShell also works on Linux/macOS if you have `pwsh`: `pwsh ./run-interview.ps1`.)

   The runner starts the simulator, points it at your orchestrator (`http://localhost:5090` by
   default), runs each scenario, and prints a per-scenario and total score summary. Practice
   scenarios: `warmup-01`, `smoke-01`, `sample-easy`, `sample-moderate`, `sample-hard`,
   `sample-brutal`. The real evaluation uses **different, hidden** scenarios.

Good luck.
