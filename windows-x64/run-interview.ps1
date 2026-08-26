#requires -Version 7.0
<#
.SYNOPSIS
    Interview harness runner. Starts the mock ADO engine and drives a prescripted list of
    scenarios (by name), scoring the candidate's orchestrator on each in turn.

.DESCRIPTION
    The candidate gets their orchestrator running (listening for pushes at /requests), then
    the interviewer runs:  pwsh -command .\run-interview.ps1
    For each scenario the engine loads it BY NAME, runs the scenario's horizon plus a retry
    buffer (paced at -MinuteMillis per simulated minute), then scores before moving to the
    next. Only processes this script starts are stopped on exit.

    With -StartReference the harness owns the orchestrator too, so it runs each scenario in FULL
    ISOLATION: a fresh mock server AND a fresh reference orchestrator per scenario, both torn
    down before the next. Nothing carries over between scenarios, so there are no stale
    cross-scenario requests. The per-scenario reports are stitched into one combined report.

.EXAMPLE
    pwsh -command .\run-interview.ps1              # run the prescripted list against :5090

.EXAMPLE
    ./run-interview.ps1 -StartReference            # self-test using the bundled reference
#>
[CmdletBinding()]
param(
    # Scenarios to run, in order, BY NAME. The engine loads each by name.
    [string[]] $Scenarios = @('sample-easy', 'sample-moderate', 'sample-hard', 'sample-brutal'),

    [string] $MockAdoUrl = 'http://localhost:5080',
    [string] $OrchestratorUrl = 'http://localhost:5090',

    # ms of real time per simulated minute.
    [int] $MinuteMillis = 250,

    # Extra sim-minutes to run past each scenario's horizon so retried/late work can finish.
    [int] $BufferMinutes = 30,

    # Load plaintext scenario files from scenarios/ instead of the ones baked into the exe (authoring).
    [switch] $UseFile,

    # Also launch the bundled reference orchestrator (for self-testing the harness).
    [switch] $StartReference,

    # Skip 'dotnet build' (assume already built).
    [switch] $SkipBuild,

    # Path to the published MockAdo.Server.exe. If omitted, uses dist/candidate/ when present,
    # otherwise falls back to 'dotnet run' from source (authoring only).
    [string] $ServerExe
)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$slnx = Join-Path $appRoot 'AdoInterviewSim.slnx'
$serverProj = Join-Path $appRoot 'src/MockAdo.Server/MockAdo.Server.csproj'
$refProj = Join-Path $appRoot 'src/Reference.Orchestrator/Reference.Orchestrator.csproj'
$started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

# Prefer a published binary (an interview machine — or the candidate kit — may have only the
# binary). The candidate kit puts the OS-appropriate binary next to this script (per-OS folder).
$serverBinName = if ($IsWindows) { 'MockAdo.Server.exe' } else { 'MockAdo.Server' }
if (-not $ServerExe) {
    foreach ($cand in @(
        (Join-Path $PSScriptRoot $serverBinName),                  # per-OS kit layout (binary beside this script)
        (Join-Path $appRoot $serverBinName),                       # flat kit layout (binary at repo root)
        (Join-Path $appRoot 'dist/candidate/MockAdo.Server.exe')   # interviewer publish output
    )) { if ($cand -and (Test-Path $cand)) { $ServerExe = $cand; break } }
}
$haveSource = Test-Path $serverProj

function Test-Endpoint([string] $url) {
    try { Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

function Wait-Endpoint([string] $url, [string] $name, [int] $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Endpoint $url) { Write-Host "  $name is up." -ForegroundColor Green; return }
        Start-Sleep -Milliseconds 500
    }
    throw "$name did not become ready at $url within ${timeoutSec}s."
}

function Show-Score($s) {
    $line = '-' * 64
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host (" SCENARIO {0}  (seed {1}, horizon {2}m)" -f $s.scenario, $s.seed, $s.horizonMinutes) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host (" POINTS EARNED: {0}   (additive; ceiling is scenario-dependent)" -f $s.pointsEarned) -ForegroundColor Yellow
    Write-Host (" completed={0} rlHits={1} rlFails={2} rateLimited(final)={3} canceled={4} missed={5} unfulfilled={6} total={7}" -f `
        $s.completed, $s.rateLimitedRequests, $s.rateLimitFailures, $s.rateLimited, $s.canceled, $s.missed, $s.unfulfilled, $s.totalRequests)
    Write-Host ''
    foreach ($c in $s.categories) {
        Write-Host ("  {0,-14} {1,8} pts   {2}" -f $c.name, $c.points, $c.detail)
    }
    if ($s.notes -and $s.notes.Count -gt 0) {
        Write-Host "`n  Notes:" -ForegroundColor DarkYellow
        foreach ($n in $s.notes) { Write-Host "   - $n" }
    }
    Write-Host "$line`n" -ForegroundColor Cyan
}

function Stop-Proc($p) {
    if ($p -and -not $p.HasExited) { try { $p.Kill($true) } catch { } }
}

function Start-MockServer {
    # Start the mock ADO server if one isn't already answering. Returns the process (or $null).
    if (Test-Endpoint "$MockAdoUrl/sim/clock") {
        Write-Host "  mock ADO server already running at $MockAdoUrl (leaving it alone)." -ForegroundColor DarkGray
        return $null
    }
    if ($ServerExe) {
        if (-not $IsWindows) { & chmod +x $ServerExe 2>$null }   # the exec bit isn't preserved when published from Windows
        Write-Host "  starting mock ADO server..." -ForegroundColor Cyan
        $p = Start-Process $ServerExe -PassThru -ArgumentList @('--urls', $MockAdoUrl)
    }
    elseif ($haveSource) {
        Write-Host "  starting mock ADO server (dotnet run)..." -ForegroundColor Cyan
        $p = Start-Process dotnet -PassThru -ArgumentList @('run', '--project', $serverProj, '-c', 'Debug', '--no-build', '--urls', $MockAdoUrl)
    }
    else {
        throw "No MockAdo.Server.exe found (looked in dist/candidate/) and no source at $serverProj. Pass -ServerExe <path>."
    }
    Wait-Endpoint "$MockAdoUrl/sim/clock" 'Mock ADO server'
    return $p
}

function Start-ReferenceOrchestrator {
    if (-not (Test-Path $refProj)) { throw "-StartReference needs the source at $refProj (self-test only)." }
    Write-Host "  starting reference orchestrator..." -ForegroundColor Cyan
    $env:MOCK_ADO_URL = "$MockAdoUrl/interview/challenge"
    $p = Start-Process dotnet -PassThru -ArgumentList @('run', '--project', $refProj, '-c', 'Debug', '--no-build', '--urls', $OrchestratorUrl)
    Wait-Endpoint $OrchestratorUrl 'Reference orchestrator'
    return $p
}

function Set-SimTarget {
    Invoke-RestMethod -Method Post -Uri "$MockAdoUrl/sim/config" -ContentType application/json `
        -Body (@{ orchestratorUrl = $OrchestratorUrl } | ConvertTo-Json) | Out-Null
}

function Invoke-OneScenario([string] $name, [string] $stamp, [string] $reportsDir, $summary) {
    # Load first (this resets the sim clock to 0), then start the episode so the orchestrator's
    # timeline sampler baselines at minute 0.
    if ($UseFile) { $load = Invoke-RestMethod -Method Post -Uri "$MockAdoUrl/sim/load-file?name=$name" }
    else { $load = Invoke-RestMethod -Method Post -Uri "$MockAdoUrl/sim/load-embedded?name=$name" }
    try { Invoke-RestMethod -Method Post -Uri "$OrchestratorUrl/episode/start" -ContentType application/json -Body (@{ scenario = $name } | ConvertTo-Json) -TimeoutSec 5 | Out-Null } catch { }
    $estSec = [math]::Round((($load.horizon + $BufferMinutes) * $MinuteMillis) / 1000)
    Write-Host ("  loaded {0}: {1} requests, horizon {2}m (+{3}m buffer, ~{4}s)" -f $load.loaded, $load.requests, $load.horizon, $BufferMinutes, $estSec)
    $score = Invoke-RestMethod -Method Post -Uri "$MockAdoUrl/sim/run?minuteMillis=$MinuteMillis&extraMinutes=$BufferMinutes" -TimeoutSec 7200
    Show-Score $score
    try { Invoke-RestMethod -Method Post -Uri "$OrchestratorUrl/episode/end" -ContentType application/json -Body ($score | ConvertTo-Json -Depth 8) -TimeoutSec 5 | Out-Null } catch { }
    $score | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $reportsDir "$name-$stamp.json")
    $summary.Add([pscustomobject]@{
            Scenario    = $name
            Points      = $score.pointsEarned
            Completed   = "$($score.completed)/$($score.totalRequests)"
            RlHits      = $score.rateLimitedRequests
            RlFails     = $score.rateLimitFailures
            Unfulfilled = $score.unfulfilled
        })
}

function Get-OrchestratorReport {
    try { return Invoke-RestMethod -Method Get -Uri "$OrchestratorUrl/report" -TimeoutSec 20 } catch { return $null }
}

function Join-Reports([System.Collections.Generic.List[string]] $htmls, [double] $totalPoints, [string] $outPath) {
    # Each fresh orchestrator emits a self-contained single-scenario report; stitch their sections
    # (and merge the summary rows) into one document that reuses the first report's head/CSS.
    if ($htmls.Count -eq 0) { return }
    $first = $htmls[0]
    $cut = $first.IndexOf('<h2>Summary</h2>')
    if ($cut -lt 0) { $first | Set-Content -Path $outPath -Encoding UTF8; return }
    $head = $first.Substring(0, $cut)
    $thead = [regex]::Match($first, "<table class='summary'><thead>.*?</thead>", 'Singleline').Value
    $rows = ($htmls | ForEach-Object { [regex]::Match($_, "<tr><td><a href='#.*?</tr>", 'Singleline').Value }) -join ''
    $totalRow = "<tr class='total'><td>Total</td><td class='num'>$([math]::Round($totalPoints, 1))</td><td colspan='6'></td></tr>"
    $sections = ($htmls | ForEach-Object { [regex]::Match($_, "<section id=.*?</section>", 'Singleline').Value }) -join ''
    ($head + "<h2>Summary</h2><table class='summary'>$thead<tbody>$rows$totalRow</tbody></table>" + $sections + "</body></html>") |
        Set-Content -Path $outPath -Encoding UTF8
}

try {
    if (-not $SkipBuild -and -not $ServerExe -and (Test-Path $slnx)) {
        Write-Host "Building solution..." -ForegroundColor Cyan
        dotnet build $slnx -v q --nologo | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "build failed" }
    }

    $reportsDir = Join-Path $appRoot 'reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $summary = [System.Collections.Generic.List[object]]::new()
    $reportHtmls = [System.Collections.Generic.List[string]]::new()

    if ($StartReference) {
        # Full isolation: fresh server + fresh reference orchestrator per scenario, torn down before
        # the next. Nothing carries over, so there are no stale cross-scenario requests.
        for ($i = 0; $i -lt $Scenarios.Count; $i++) {
            $name = $Scenarios[$i]
            Write-Host "`n=== Scenario $($i + 1)/$($Scenarios.Count): $name  (fresh server + orchestrator) ===" -ForegroundColor Magenta

            $srv = Start-MockServer
            if ($srv) { $started.Add($srv) }
            $ref = Start-ReferenceOrchestrator
            $started.Add($ref)
            Set-SimTarget

            Invoke-OneScenario $name $stamp $reportsDir $summary

            $html = Get-OrchestratorReport
            if ($html) {
                $per = Join-Path $reportsDir "interview-$stamp-$name.html"
                $html | Set-Content -Path $per -Encoding UTF8
                $reportHtmls.Add($html)
                Write-Host "  report -> $per" -ForegroundColor Green
            }

            Stop-Proc $ref
            Stop-Proc $srv
            Start-Sleep -Seconds 1   # let the sockets free before the next iteration rebinds them
        }
    }
    else {
        # Candidate mode: their orchestrator runs externally and persists; start ONE server and
        # drive every scenario against their live orchestrator.
        $srv = Start-MockServer
        if ($srv) { $started.Add($srv) }
        if (-not (Test-Endpoint $OrchestratorUrl)) {
            Write-Host "WARNING: nothing is answering at $OrchestratorUrl. Start your orchestrator first." -ForegroundColor Yellow
        }
        Set-SimTarget
        for ($i = 0; $i -lt $Scenarios.Count; $i++) {
            Write-Host "`n=== Scenario $($i + 1)/$($Scenarios.Count): $($Scenarios[$i]) ===" -ForegroundColor Magenta
            Invoke-OneScenario $Scenarios[$i] $stamp $reportsDir $summary
            if ($i -lt $Scenarios.Count - 1) { Start-Sleep -Seconds 2 }
        }
        $html = Get-OrchestratorReport
        if ($html) { $reportHtmls.Add($html) }
    }

    # --- Summary --------------------------------------------------------------
    Write-Host "`n================= INTERVIEW SUMMARY =================" -ForegroundColor Cyan
    ($summary | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
    $totalPoints = [math]::Round((($summary | Measure-Object -Property Points -Sum).Sum), 1)
    Write-Host ("`nTotal points across {0} scenario(s): {1}" -f $summary.Count, $totalPoints) -ForegroundColor Yellow

    # --- Combined orchestrator HTML report ------------------------------------
    if ($reportHtmls.Count -gt 0) {
        $htmlPath = Join-Path $reportsDir "interview-$stamp.html"
        if ($StartReference) { Join-Reports $reportHtmls $totalPoints $htmlPath }
        else { $reportHtmls[0] | Set-Content -Path $htmlPath -Encoding UTF8 }
        Write-Host "`nOrchestrator report -> $htmlPath" -ForegroundColor Green
    }
    else { Write-Host "`n(the orchestrator did not provide an HTML report)" -ForegroundColor DarkGray }
}
finally {
    foreach ($p in $started) {
        if ($p -and -not $p.HasExited) {
            Write-Host "Stopping process $($p.Id) ..." -ForegroundColor DarkGray
            try { $p.Kill($true) } catch { }
        }
    }
}
