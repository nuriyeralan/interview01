# API Reference

The **mock ADO REST** surface your orchestrator calls, hosted by **MockAdo.Server**
(default `http://localhost:5080`).

All responses are JSON (camelCase). ADO list endpoints use the ADO `{ count, value }` envelope.

> Version: `GET /version` returns `{ service, version }`; the CLI `MockAdo.Server.exe --version`
> prints the semantic version and exits. The harness follows semantic versioning.

---

## Mock ADO REST

Base: `/{org}/{project}/_apis` — `{org}`/`{project}` are accepted but ignored.

### Pipelines

| Method | Path | Description |
| --- | --- | --- |
| GET | `/pipelines` | List pipelines (a single generic `run-binary`, id `1`). |
| GET | `/pipelines/{id}` | Get a pipeline. |

### Runs

| Method | Path | Description |
| --- | --- | --- |
| POST | `/pipelines/{id}/runs` | Queue a run. Body must carry variables `requestId` and `poolId`. |
| GET | `/pipelines/{id}/runs` | List all runs. Optional `?state=inProgress` returns only active runs. |
| GET | `/pipelines/{id}/runs/{runId}` | Get one run. |
| POST | `/pipelines/{id}/runs/{runId}/cancel` | Cancel a run (frees its VM). |
| PATCH | `/build/builds/{runId}` | Cancel a run (ADO build mechanism). |
| GET | `/build/builds/{runId}/timeline` | Run timeline with per-job state/result and failure issues. |
| GET | `/build/builds/{runId}/logs` | Post-hoc per-minute token usage for a run (see below). |

**Queue body**

```json
{
  "variables": {
    "requestId":    { "value": "3f2504e0-4f89-41d3-9a0c-0305e82c3301" },
    "poolId":       { "value": "1" },
    "architecture": { "value": "intel-x64" },
    "binaryName":   { "value": "bear.dll" }
  }
}
```

`requestId`, `poolId`, and `binaryName` are required. `architecture` is optional and asserts
the ISA the run targets; when omitted it defaults to the request's `requiredArchitecture`.
`binaryName` must be a bare `<name>.dll` (no path, extension present). The target pool must
match the request's **job type** and the architecture.

**Queue responses**

| Status | Meaning |
| --- | --- |
| 200 | Run created (`AdoRun` returned, `state: "inProgress"`). |
| 400 | Missing variables, **bad input** (malformed or unknown `binaryName`), job-type mismatch, or architecture mismatch. |
| 404 | Unknown pipeline / pool / request id. |
| 409 | Pool full, request already running, or request already completed. |

**AdoRun**

```json
{
  "id": 1001,
  "name": "#1001 moose.dll",
  "state": "inProgress",          // inProgress | canceling | completed
  "result": null,                  // succeeded | failed | canceled (when completed)
  "pipeline": { "id": 1, "name": "run-binary" },
  "createdDate": "1970-01-01T00:42:00+00:00",
  "finishedDate": null,
  "variables": { "requestId": { "value": "3f2504e0-4f89-41d3-9a0c-0305e82c3301" }, "poolId": { "value": "1" } },
  "url": "/_apis/pipelines/1/runs/1001"
}
```

**Timeline** (`GET /build/builds/{runId}/timeline`) — the `issues` explain *why* a run failed,
so you can analyze and classify failures (e.g. attribute a rate limit to a specific model):

```json
{
  "records": [
    {
      "id": "1001-job", "type": "Job", "name": "moose.dll",
      "state": "completed", "result": "failed",
      "startTime": "1970-01-01T00:42:00+00:00", "finishTime": "1970-01-01T00:47:00+00:00",
      "issues": [ { "type": "error", "message": "rate-limited: model 'model-odyssey' exceeded fleet cap of 4000000 tokens/min" } ]
    }
  ]
}
```

**Token usage log** (`GET /build/builds/{runId}/logs`) — after a run completes or is rate-limited,
returns its actual per-minute token demand. A succeeded run returns its whole profile; a
rate-limited run returns minutes up to and including the failing minute (`failedAtMinute`);
an in-progress run returns only elapsed minutes. Future minutes are never revealed. Use it to
learn each binary/job-type's token profile.

```json
{
  "runId": 1001, "requestId": "3f2504e0-...", "binaryName": "moose.dll", "jobType": "Prove",
  "state": "completed", "result": "failed",
  "rateLimited": true, "failedAtMinute": 3, "rateLimitedModel": "model-odyssey",
  "perMinute": [
    { "minute": 0, "tokens": { "model-odyssey": 850000 } },
    { "minute": 1, "tokens": { "model-odyssey": 910000, "model-haiku": 120000 } },
    { "minute": 2, "tokens": { "model-odyssey": 1200000 } },
    { "minute": 3, "tokens": { "model-odyssey": 1400000 } }
  ]
}
```

### Distributed Task (pools / agents / queues)

| Method | Path | Description |
| --- | --- | --- |
| GET | `/distributedtask/pools` | List pools with `size`, `architecture`, `jobType`, `availableSlots`. |
| GET | `/distributedtask/pools/{id}` | Get one pool. |
| GET | `/distributedtask/pools/{id}/agents` | List agents; each has `assignmentStatus` (`idle`/`busy`) and `currentRunId`. |
| GET | `/distributedtask/queues` | List agent queues (1:1 with pools). |

**AdoPool**

```json
{ "id": 1, "name": "scan-intel", "isHosted": false, "size": 4, "architecture": "intel-x64", "jobType": "Scan", "availableSlots": 2 }
```

> `architecture` and `availableSlots` are convenience fields beyond the real ADO schema,
> provided so the orchestrator can reason about capacity directly.

---

## Orchestrator push contract

The simulator POSTs to `{orchestratorUrl}/requests` on each arrival:

```json
{ "id": "3f2504e0-4f89-41d3-9a0c-0305e82c3301", "arrivalMinute": 42, "requiredArchitecture": "intel-x64", "jobType": "Prove", "binaryName": "moose.dll", "priority": "P1" }
```

Fire-and-forget: respond fast (`202`) and schedule asynchronously.

