# Candidate Brief — Pipeline Orchestrator

Welcome. You are building an **orchestrator** for a fleet of Azure DevOps Pipeline
agents. Jobs arrive continuously; you must schedule them onto agent pools to maximize
throughput and honour priority, while respecting hidden resource limits you can only
learn by observation.

You will use **VS Code + agent mode**. You may use any language/stack for your
orchestrator; it only needs to (a) accept HTTP pushes and (b) call the ADO REST API.

## What the jobs are

Each request is a code-analysis job of one of two types:

- **Scan** — analyzes a binary via a multi-model *debate*, consuming AI-model tokens roughly
  proportional to the size of that binary's source.
- **Prove** — takes a scan's findings and attempts to *prove* them, also consuming tokens.

The AI models used by these jobs are **agentic and rate-limited**: each model has a
fleet-wide tokens-per-minute budget shared by every running job. If concurrently running
jobs push a model over its per-minute limit, the offending job is **rate-limited and fails**.

There are three models, with these fleet-wide per-minute token caps:

| Model | Tokens/min cap |
| --- | --- |
| `model-opus-4.6` | 10,000,000 |
| `model-odyssey` | 4,000,000 |
| `model-haiku` | 16,000,000 |

## Running the simulator

The kit ships a self-contained simulator (no runtime install needed) plus a runner for each OS,
in a per-platform folder. **Use the folder that matches your machine:**

| Platform | Folder | Binary | Runner |
| --- | --- | --- | --- |
| Windows (x64) | `windows-x64/` | `MockAdo.Server.exe` | `run-interview.ps1` |
| Linux (x64) | `linux-x64/` | `MockAdo.Server` | `run-interview.sh` |
| macOS (Intel) | `macos-x64/` | `MockAdo.Server` | `run-interview.sh` |
| macOS (Apple Silicon) | `macos-arm64/` | `MockAdo.Server` | `run-interview.sh` |

Normally you just run the runner for your platform — it starts the simulator for you (see the
README quick start). To launch the simulator directly:

**Windows (PowerShell):**
```powershell
cd windows-x64
.\MockAdo.Server.exe           # listens on http://localhost:5080
.\MockAdo.Server.exe --version # prints the semantic version and exits
```

**Linux / macOS (bash):**
```bash
cd linux-x64                   # or macos-x64 / macos-arm64
chmod +x ./MockAdo.Server      # first run only
./MockAdo.Server               # listens on http://localhost:5080
./MockAdo.Server --version     # prints the semantic version and exits
```

The scenarios' arrival schedules and hidden parameters (duration, token demand) are not
surfaced through the API. The challenge is to *learn* the hidden behaviour by observation,
exactly as you would with a real, opaque system.

## What you receive

The simulator **pushes** each new request to your service, fire-and-forget:

```
POST {your-orchestrator}/requests
Content-Type: application/json

{
  "id": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
  "requiredArchitecture": "intel-x64",
  "jobType": "Prove",
  "binaryName": "moose.dll",
  "priority": "P1"
}
```

- Delivery is **not** retried and the simulator does **not** wait for you. If you are slow
  or drop the payload, that job may never be scheduled — which counts against you.
- Respond quickly (e.g. `202 Accepted`) and do your scheduling asynchronously.
- **These are the only fields you get.** Duration and resource consumption are hidden.

## What you can do (mock ADO REST)

Base URL: `http://localhost:5080/{org}/{project}/_apis` (org/project are placeholders).

- **Read pools/capacity:** `GET /distributedtask/pools`, `.../pools/{id}`, `.../pools/{id}/agents`, `GET /distributedtask/queues`
- **Queue a run:** `POST /pipelines/1/runs` with variables `requestId` and `poolId`
- **Track runs:** `GET /pipelines/1/runs`, `.../runs/{runId}`
- **Diagnose a failure:** `GET /build/builds/{runId}/timeline` — the timeline's `issues` explain *why* a run failed.
- **Learn a job's token usage:** `GET /build/builds/{runId}/logs` — after a run completes or is rate-limited, returns its **per-minute token demand** (the whole run if it succeeded, up to and including the failing minute if it was rate-limited).
- **Cancel a run:** `POST /pipelines/1/runs/{runId}/cancel` (or `PATCH /build/builds/{runId}`)

Queue example:

```
POST /pipelines/1/runs
{
  "variables": {
    "requestId":    { "value": "3f2504e0-4f89-41d3-9a0c-0305e82c3301" },
    "poolId":       { "value": "1" },
    "architecture": { "value": "intel-x64" },
    "binaryName":   { "value": "bear.dll" }
  }
}
```

`architecture` is optional and asserts the ISA the run targets (defaults to the request's
`requiredArchitecture`). `binaryName` is **required** — the binary to run, as a bare
`<name>.dll`. The pool validates it and rejects bad input (`400`). Full details: [API.md](API.md).

## The rules of the world

1. **Job-type isolation.** Every pool serves exactly one job type — either **Scan** or
   **Prove** — and the two are physically isolated. A `Scan` job can only run on a Scan
   pool and a `Prove` job only on a Prove pool. Each pool advertises its `jobType`,
   `architecture`, and `size`. Queuing a job to a pool of the wrong job type is rejected (`400`).
2. **Architecture matching.** A run is rejected (`400`) unless the pool's architecture
   matches the run's architecture (the `architecture` variable, or the request's
   `requiredArchitecture` if you don't override it).
3. **One VM per job.** A running job holds exactly one VM slot in its pool for its entire
   (hidden) duration. Queuing to a full pool is rejected (`409`).
4. **Hidden duration.** You learn a job finished only by observing its run reach
   `state = completed`, `result = succeeded`.
5. **Hidden, per-minute, multi-model token demand.** Each minute a job may consume tokens
   of one or more *models*. Each model has a **fleet-wide** tokens/minute cap shared by
   **every** running job across **all** pools. If the fleet exceeds a model's cap in any
   minute, offending jobs are **rate-limited and fail** (`result = failed`, VM freed).
6. **Resubmission is allowed.** A failed or canceled job is yours to re-queue.
7. **Priority & preemption.** Priorities are `P0` (highest) .. `P3`. When all compatible
   pools are full and higher-priority work is waiting, you are expected to **cancel** a
   lower-priority running job to admit it (and later resubmit the victim).

## How you are graded

Scoring is **additive**: you start at **0 points** and earn points for good outcomes. There
is no fixed maximum — a higher total is better, and nothing is ever deducted. Points are
awarded per request (except Efficiency, which is fleet-wide), so **completing more work —
especially high-priority work, quickly and cleanly — always increases your score.**

**Per request** (a request can earn points in several categories at once):

| Category | When you earn it | Points |
| --- | --- | --- |
| **Completion** | The request's run finishes `succeeded`. Higher priority is worth more. | `P0` = 40, `P1` = 30, `P2` = 20, `P3` = 10 |
| **SlaBonus** | It completed **within its tier's SLA** (arrival → completion). | `P0` = 20, `P1` = 15, `P2` = 10, `P3` = 5 |
| **Promptness** | You first scheduled it **within the 5-minute grace window** of arrival, and it completed. | +3 |
| **Resilience** | It completed **without ever being rate-limited** (no token-cap failure). | +5 |

**Fleet-wide:**

| Category | When you earn it | Points |
| --- | --- | --- |
| **Efficiency** | Proportional to average VM utilization across the run. | up to 100 (utilization × 100) |

Priority SLAs (arrival → completion): `P0 ≤ 30m`, `P1 ≤ 60m`, `P2 ≤ 120m`, `P3 ≤ 240m`.
The grace window is **5 sim-minutes**.

### What this means for your strategy

- **Throughput is king.** Every completion adds points; unscheduled or failed work adds
  nothing. Keep the fleet busy — idle VMs are points left on the table (see Efficiency).
- **Prioritize.** A completed `P0` is worth 4× a `P3` (40 vs 10), plus a bigger SLA bonus
  (20 vs 5). When capacity is scarce, do the high-priority work first — and preempt a
  lower-priority run to make room if you must.
- **Be quick.** Schedule as soon as a compatible VM is free (the +3 Promptness bonus and the
  SLA bonuses both reward speed).
- **Be clean.** A rate-limit failure costs you the Resilience bonus *and* forces a resubmit
  (more delay, risking the SLA). Learn each binary's behaviour and avoid over-subscribing a
  model's token budget.

Good luck.
