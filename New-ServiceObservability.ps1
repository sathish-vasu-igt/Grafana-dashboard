<#
.SYNOPSIS
    Create or update Grafana dashboards for Helm chart services, discovered from the chart itself.
.DESCRIPTION
    Reads the chart's values.yaml to discover services. Any block that declares a
    fullnameOverride is treated as a deployable service; the block key is the chart/subchart
    name and fullnameOverride is the Prometheus selector value. No service naming prefix is
    assumed - whatever the chart declares is what the dashboard targets.

    For each service the script resolves the dashboard directory, then decides:
      UPDATE - an existing dashboard already targets this service. The existing file name,
               dashboard uid and title are preserved so the Grafana dashboard and the Helm
               ConfigMap name (hashed from the file path) stay stable. Requires -Force.
      CREATE - no dashboard targets this service yet. A new file is created from the chart name.

    Panels come from Generate-Service-Dashboard.ps1. Per-service display names, optional
    feature rows and extra metric panels come from dashboard-overrides.json.
.PARAMETER ChartPath
    Chart directory containing values.yaml (umbrella chart root or a standalone chart).
.PARAMETER Mode
    Umbrella or Standalone. Auto-detected from the number of services found in values.yaml.
.PARAMETER Service
    Chart/subchart name of a single service to process. Omit with -All.
.PARAMETER All
    Process every service discovered in the chart.
.PARAMETER DashboardDir
    Overrides the dashboard output directory (default: <ChartPath>\dashboard).
.PARAMETER OverridesPath
    Path to dashboard-overrides.json (default: beside this script).
.PARAMETER SelectorLabel
    Prometheus label used to scope panels to the service (default from overrides: job).
.PARAMETER SelectorValue
    Explicit selector value, for standalone charts whose fullnameOverride is empty
    (Helm derives the release name, e.g. floornet-acerestsvc).
.PARAMETER PrometheusUrl
    Optional Prometheus base URL. When supplied, each resolved selector is checked
    against the live label values so mismatches are reported before writing.
.PARAMETER ServiceRepoPath
    Optional path to the service's source repo. When supplied (or set per-service via
    "repoPath" in dashboard-overrides.json), the repo is scanned for API/Service/DAL/
    Database/Health/Metrics evidence before any optional section is generated - a
    service without a DAL never gets a PMDAL row, regardless of the config defaults.
.PARAMETER Force
    Overwrite the existing dashboard in place instead of creating a new file beside it.
    A .bak copy is written first.
.PARAMETER IncludeMain
    Also generate a single cross-service overview dashboard covering every discovered service.
.PARAMETER MainTitle
    Title for the overview dashboard (default: "<chart> Operations Dashboard").
.PARAMETER DryRun
    Show the resolved chart folder, dashboard names and planned actions without writing.
.EXAMPLE
    .\New-ServiceObservability.ps1 -All -DryRun
    Confirm the chart folder and the create/update plan for every discovered service.
.EXAMPLE
    .\New-ServiceObservability.ps1 -Service playeropssvc -Force
    Update the existing PlayerOps dashboard in place, preserving its file name, uid and title.
.EXAMPLE
    .\New-ServiceObservability.ps1 -ChartPath C:\charts\walletsvc -Mode Standalone -All
    Create a dashboard for a new standalone chart, named from the chart.
#>

[CmdletBinding()]
param(
    [string]$ChartPath,
    [ValidateSet('Umbrella', 'Standalone')][string]$Mode,
    [string]$Service,
    [switch]$All,
    [string]$DashboardDir,
    [string]$OverridesPath,
    [string]$SelectorLabel,
    [string]$SelectorValue,
    [string]$PrometheusUrl,
    [string]$ServiceRepoPath,
    [string]$Namespace,
    [switch]$Force,
    [switch]$IncludeMain,
    [string]$MainTitle,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OverridesPath) { $OverridesPath = Join-Path $scriptRoot 'dashboard-overrides.json' }
$generator = Join-Path $scriptRoot 'Generate-Service-Dashboard.ps1'

foreach ($required in @($generator, $OverridesPath)) {
    if (-not (Test-Path $required)) {
        Write-Host "ERROR: Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$config = Get-Content $OverridesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$defaults = $config.defaults
if (-not $SelectorLabel) { $SelectorLabel = $defaults.selectorLabel }

# A sanitised export (blank metric names/paths) is meant for handing to another team, not for
# generating your own dashboards - warn loudly instead of silently skipping every optional row.
$blankDefaultFeatures = @('authMetric', 'clientMetric', 'rabbitmqContainer', 'redisInstance') |
    Where-Object { [string]::IsNullOrWhiteSpace($defaults.features.$_) }
if ($blankDefaultFeatures.Count -gt 0) {
    Write-Host "WARNING: '$OverridesPath' has blank defaults for: $($blankDefaultFeatures -join ', ')" -ForegroundColor Yellow
    Write-Host "         This looks like the sanitised export (dist\dashboard-toolkit). Auth/Client/RabbitMQ/Redis" -ForegroundColor Yellow
    Write-Host "         sections will be skipped unless a per-service override supplies real values." -ForegroundColor Yellow
}

# A values.yaml block that declares fullnameOverride is a deployable service; the key is its chart name.
function Get-ChartService {
    param([string]$ValuesPath)

    $lines = @(Get-Content $ValuesPath)
    $keys = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)([A-Za-z][A-Za-z0-9_.-]*):\s*(#.*)?$') {
            $keys += [pscustomobject]@{ Index = $i; Indent = $Matches[1].Length; Name = $Matches[2] }
        }
    }
    if ($keys.Count -eq 0) { return @() }

    $baseIndent = ($keys | Measure-Object -Property Indent -Minimum).Minimum
    $topKeys = @($keys | Where-Object { $_.Indent -eq $baseIndent })

    $services = @()
    for ($k = 0; $k -lt $topKeys.Count; $k++) {
        $start = $topKeys[$k].Index
        $end = if ($k + 1 -lt $topKeys.Count) { $topKeys[$k + 1].Index - 1 } else { $lines.Count - 1 }
        if ($end -lt $start) { continue }
        $block = ($lines[$start..$end]) -join "`n"

        if ($block -notmatch 'fullnameOverride:') { continue }

        $fullName = ''
        if ($block -match 'fullnameOverride:\s*"?([^"\r\n#]*)"?') { $fullName = $Matches[1].Trim() }

        # An empty fullnameOverride means Helm derives the name at release time, so this is not a discoverable service.
        if ([string]::IsNullOrWhiteSpace($fullName)) { continue }

        $ns = ''
        if ($block -match 'namespace:\s*"?([^"\r\n#]+)"?') { $ns = $Matches[1].Trim() }

        $services += [pscustomobject]@{
            ChartName     = $topKeys[$k].Name
            SelectorValue = $fullName
            Namespace     = $ns
        }
    }
    return $services
}

# Subchart folders name the services directly, and each may carry its own values.yaml.
function Get-SubchartService {
    param([string]$SubchartRoot, [switch]$PerChartDashboard)

    if (-not (Test-Path $SubchartRoot)) { return @() }

    $found = @()
    foreach ($dir in Get-ChildItem $SubchartRoot -Directory -EA SilentlyContinue) {
        $selector = $dir.Name
        $ns = ''
        $subValues = Join-Path $dir.FullName 'values.yaml'

        if (Test-Path $subValues) {
            $content = Get-Content $subValues -Raw
            if ($content -match 'fullnameOverride:\s*"?([^"\r\n#]*)"?') {
                $value = $Matches[1].Trim()
                if ($value) { $selector = $value }
            }
            if ($content -match 'namespace:\s*"?([^"\r\n#]+)"?') { $ns = $Matches[1].Trim() }
        }

        $found += [pscustomobject]@{
            ChartName     = $dir.Name
            SelectorValue = $selector
            Namespace     = $ns
            DashboardDir  = if ($PerChartDashboard) { Join-Path $dir.FullName $defaults.dashboardSubPath } else { $null }
        }
    }
    return $found
}

# Confirms the selector actually exists in Prometheus so typos surface before dashboards are written.
function Get-PrometheusLabelValue {
    param([string]$BaseUrl, [string]$Label)

    $uri = "$($BaseUrl.TrimEnd('/'))/api/v1/label/$Label/values"
    try {
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 20
        if ($response.status -eq 'success') { return @($response.data) }
    }
    catch {
        Write-Host "  WARNING: Prometheus query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $null
}

# Ground truth for whether an optional component (auth/pmdal/clients/rabbitmq/redis) is
# actually implemented: query Prometheus for the metric instead of guessing from source,
# since instrumentation often lives in a shared library the chart repo doesn't contain.
function Test-PrometheusSeriesExists {
    param([string]$BaseUrl, [string]$Query)

    $uri = "$($BaseUrl.TrimEnd('/'))/api/v1/query?query=$([uri]::EscapeDataString($Query))"
    try {
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 20
        if ($response.status -eq 'success') { return (@($response.data.result).Count -gt 0) }
    }
    catch {
        Write-Host "  WARNING: Prometheus query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $null
}

# A configured section with no matching data is a real gap, not a config mistake - print the
# prometheus-net instrumentation and PromQL needed to close it, then skip the section so the
# generated dashboard doesn't ship an empty panel.
function Write-InstrumentationGap {
    param([string]$Kind, [string]$MetricName, [string]$LabelFilter)

    $header = if ($Kind -in @('rabbitmq-service', 'redis-service')) {
        "  GAP: '$MetricName' does not exist yet - no service-tagged counter found in source"
    }
    else {
        "  GAP: '$MetricName' has no data in Prometheus - section skipped for this run"
    }
    Write-Host $header -ForegroundColor Yellow
    $sel = if ($LabelFilter) { "{$LabelFilter}" } else { '' }
    switch ($Kind) {
        'auth' {
            Write-Host "    Add (prometheus-net):" -ForegroundColor DarkGray
            Write-Host "      private static readonly Counter AuthValidations = Metrics.CreateCounter(" -ForegroundColor DarkGray
            Write-Host "          `"$MetricName`", `"Authentication attempts by scheme`"," -ForegroundColor DarkGray
            Write-Host "          new CounterConfiguration { LabelNames = new[] { `"scheme`" } });" -ForegroundColor DarkGray
            Write-Host "      AuthValidations.WithLabels(scheme).Inc();" -ForegroundColor DarkGray
            Write-Host "    Query: sum by (scheme) (rate($MetricName$sel[5m]))" -ForegroundColor DarkGray
        }
        'clients' {
            Write-Host "    Add (prometheus-net):" -ForegroundColor DarkGray
            Write-Host "      private static readonly Counter ClientApiHits = Metrics.CreateCounter(" -ForegroundColor DarkGray
            Write-Host "          `"$MetricName`", `"API hits by client site`"," -ForegroundColor DarkGray
            Write-Host "          new CounterConfiguration { LabelNames = new[] { `"site`", `"endpoint`", `"method`" } });" -ForegroundColor DarkGray
            Write-Host "      ClientApiHits.WithLabels(site, endpoint, method).Inc();" -ForegroundColor DarkGray
            Write-Host "    Query: topk(10, sum by (site) (rate($MetricName$sel[5m])))" -ForegroundColor DarkGray
        }
        'pmdal' {
            Write-Host "    Add (prometheus-net):" -ForegroundColor DarkGray
            Write-Host "      private static readonly Histogram PmdalProcessingTime = Metrics.CreateHistogram(" -ForegroundColor DarkGray
            Write-Host "          `"${MetricName}_Processing_Time`", `"PMDAL query processing time (seconds)`");" -ForegroundColor DarkGray
            Write-Host "      using (PmdalProcessingTime.NewTimer()) { /* execute PMDAL call */ }" -ForegroundColor DarkGray
            Write-Host "    Query: histogram_quantile(0.95, sum by (le) (rate(${MetricName}_Processing_Time_bucket[5m])))" -ForegroundColor DarkGray
        }
        'rabbitmq' {
            Write-Host "    RabbitMQ Prometheus plugin is not exposing metrics for this broker instance." -ForegroundColor DarkGray
            Write-Host "    Query: sum(rabbitmq_queue_messages_ready$sel)" -ForegroundColor DarkGray
        }
        'redis' {
            Write-Host "    Redis exporter is not exposing metrics for this instance." -ForegroundColor DarkGray
            Write-Host "    Query: sum(redis_memory_used_bytes$sel)" -ForegroundColor DarkGray
        }
        'rabbitmq-service' {
            Write-Host "    RabbitMQ.Client is used but no service-tagged counter was found - the shared" -ForegroundColor DarkGray
            Write-Host "    broker dashboard can only ever show '(All Services)', never which service." -ForegroundColor DarkGray
            Write-Host "    Add (prometheus-net):" -ForegroundColor DarkGray
            Write-Host "      private static readonly Counter RabbitMqMessages = Metrics.CreateCounter(" -ForegroundColor DarkGray
            Write-Host "          `"$MetricName`", `"Messages published/consumed by this service`"," -ForegroundColor DarkGray
            Write-Host "          new CounterConfiguration { LabelNames = new[] { `"service`", `"direction`" } });" -ForegroundColor DarkGray
            Write-Host "      RabbitMqMessages.WithLabels(`"<service-name>`", `"publish`").Inc();" -ForegroundColor DarkGray
            Write-Host "    Query: sum by (service) (rate($MetricName[5m]))" -ForegroundColor DarkGray
            Write-Host "    Set 'rabbitmqServiceMetric': `"$MetricName`" in dashboard-overrides.json to enable the panel." -ForegroundColor DarkGray
        }
        'redis-service' {
            Write-Host "    StackExchange.Redis is used but no service-tagged counter was found - the shared" -ForegroundColor DarkGray
            Write-Host "    cache dashboard can only ever show '(All Services)', never which service." -ForegroundColor DarkGray
            Write-Host "    Add (prometheus-net):" -ForegroundColor DarkGray
            Write-Host "      private static readonly Counter RedisOps = Metrics.CreateCounter(" -ForegroundColor DarkGray
            Write-Host "          `"$MetricName`", `"Redis operations by this service`"," -ForegroundColor DarkGray
            Write-Host "          new CounterConfiguration { LabelNames = new[] { `"service`" } });" -ForegroundColor DarkGray
            Write-Host "      RedisOps.WithLabels(`"<service-name>`").Inc();" -ForegroundColor DarkGray
            Write-Host "    Query: sum by (service) (rate($MetricName[5m]))" -ForegroundColor DarkGray
            Write-Host "    Set 'redisServiceMetric': `"$MetricName`" in dashboard-overrides.json to enable the panel." -ForegroundColor DarkGray
        }
    }
}

# Validate the repo before assuming anything about it: a service without a DAL should never get
# a PMDAL row, one without [Authorize] usage should never get an auth row, no matter what the
# shared config defaults say. Note: instrumentation living in a shared/precompiled library (not
# in this repo's own source) will read as "not found" here - use a per-service override to correct.
function Test-ServiceRepository {
    param([string]$RepoPath)

    if (-not $RepoPath -or -not (Test-Path $RepoPath)) { return $null }

    $csproj = @(Get-ChildItem $RepoPath -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue)
    $cs     = @(Get-ChildItem $RepoPath -Recurse -Filter '*.cs' -ErrorAction SilentlyContinue)
    if ($csproj.Count -eq 0 -and $cs.Count -eq 0) { return $null }

    $result = [ordered]@{
        ApiLayer        = [bool](@($csproj | Select-String -Pattern 'AspNetCore' -EA SilentlyContinue).Count -gt 0 -or @($cs | Select-String -Pattern '\[ApiController\]|:\s*ControllerBase' -EA SilentlyContinue).Count -gt 0)
        ServiceLayer    = [bool](@($cs | Select-String -Pattern 'class \w+(Service|BL|Manager)\b' -EA SilentlyContinue).Count -gt 0)
        Dal             = [bool](@($csproj | Select-String -Pattern 'Include="[^"]*\.?[Dd][Aa][Ll][^"]*"|Include="[^"]*Repository[^"]*"' -EA SilentlyContinue).Count -gt 0)
        Database        = [bool](@($csproj | Select-String -Pattern 'EntityFramework|Dapper|SqlClient|Npgsql|MySql' -EA SilentlyContinue).Count -gt 0)
        HealthEndpoints = [bool](@($cs | Select-String -Pattern 'MapHealthChecks|AddHealthChecks|"/health"' -EA SilentlyContinue).Count -gt 0)
        MetricsCode     = [bool](@($csproj | Select-String -Pattern 'prometheus-net' -EA SilentlyContinue).Count -gt 0 -or @($cs | Select-String -Pattern 'Metrics\.Create(Counter|Histogram|Gauge)' -EA SilentlyContinue).Count -gt 0)
        HasAuthUsage    = [bool](@($cs | Select-String -Pattern '\[Authorize' -EA SilentlyContinue).Count -gt 0)
        UsesRabbitMQ    = [bool](@($csproj | Select-String -Pattern 'RabbitMQ\.Client' -EA SilentlyContinue).Count -gt 0)
        UsesRedis       = [bool](@($csproj | Select-String -Pattern 'StackExchange\.Redis' -EA SilentlyContinue).Count -gt 0)
    }

    $pmdalMatch = @($cs | Select-String -Pattern '(\w+)_HISTOGRAM_PMDAL_Processing_Time' -EA SilentlyContinue) | Select-Object -First 1
    if ($pmdalMatch) { $result.PmdalPrefix = $pmdalMatch.Matches[0].Groups[1].Value }

    $authMatch = @($cs | Select-String -Pattern 'CreateCounter\(\s*"([^"]*auth[^"]*)"' -EA SilentlyContinue) | Select-Object -First 1
    if ($authMatch) { $result.AuthMetric = $authMatch.Matches[0].Groups[1].Value }

    $clientMatch = @($cs | Select-String -Pattern 'CreateCounter\(\s*"([^"]*client[^"]*)"' -EA SilentlyContinue) | Select-Object -First 1
    if ($clientMatch) { $result.ClientMetric = $clientMatch.Matches[0].Groups[1].Value }

    # Does this service tag its own RabbitMQ/Redis usage with a "service" label? Without this,
    # the shared broker/cache dashboard can only ever show "(All Services)" combined.
    $rmqAppMatch = @($cs | Select-String -Pattern 'CreateCounter\(\s*"([^"]*(?:rabbitmq|queue|message)[^"]*)"' -EA SilentlyContinue) | Select-Object -First 1
    if ($rmqAppMatch) { $result.AppRabbitMetric = $rmqAppMatch.Matches[0].Groups[1].Value }

    $redisAppMatch = @($cs | Select-String -Pattern 'CreateCounter\(\s*"([^"]*(?:redis|cache)[^"]*)"' -EA SilentlyContinue) | Select-Object -First 1
    if ($redisAppMatch) { $result.AppRedisMetric = $redisAppMatch.Matches[0].Groups[1].Value }

    return [pscustomobject]$result
}

function Write-ServiceValidation {
    param($Validation)

    Write-Host "  Service Validation Result:" -ForegroundColor Cyan
    foreach ($row in @(
        @('API Layer', $Validation.ApiLayer), @('Service Layer', $Validation.ServiceLayer),
        @('DAL', $Validation.Dal), @('Database Dependency', $Validation.Database),
        @('Health Endpoints', $Validation.HealthEndpoints), @('Metrics Code', $Validation.MetricsCode)
    )) {
        $mark, $color = if ($row[1]) { '[x]', 'Green' } else { '[ ]', 'DarkGray' }
        Write-Host "    $mark $($row[0])" -ForegroundColor $color
    }
}

# Existing dashboards are never edited, so the new file needs a free name to sit alongside.
function Get-FreeDashboardPath {
    param([string]$Directory, [string]$BaseName)

    $candidate = Join-Path $Directory "$BaseName.json"
    if (-not (Test-Path $candidate)) { return $candidate }

    $stamp = Get-Date -Format 'yyyyMMdd'
    $candidate = Join-Path $Directory "$BaseName ($stamp).json"
    $n = 2
    while (Test-Path $candidate) {
        $candidate = Join-Path $Directory "$BaseName ($stamp-$n).json"
        $n++
    }
    return $candidate
}

# Cross-service dashboard: one row per concern, every service compared side by side.
# Cross-service overview modelled on the curated ACEREST operations dashboard.
function New-MainDashboard {
    param(
        [object[]]$Services,
        [string]$Label,
        [string]$Title,
        [string]$Uid,
        [string]$OutputPath,
        [string]$Namespace,
        [string]$ClientMetric,
        [string]$AuthMetric,
        [string]$RabbitMQContainer,
        [string]$RabbitMQLabel,
        [string]$RabbitMQServiceMetric,
        [string]$RedisInstance,
        [string]$RedisLabel,
        [string]$RedisServiceMetric
    )

    $script:mid = 0
    $script:my = 0
    $panels = @()

    $sel = ($Services | ForEach-Object { [regex]::Escape($_.Selector) }) -join '|'
    $all = "$Label=~`"$sel`""
    $ns = if ($Namespace) { "namespace=`"$Namespace`"," } else { "" }
    $apiServices = @($Services | Where-Object { $_.HasApi })
    $pmdalServices = @($Services | Where-Object { $_.PmdalPrefix })

    function MkRow($t) { $script:mid++; $p = @{ id = $script:mid; type = 'row'; title = $t; collapsed = $false; panels = @(); gridPos = @{ h = 1; w = 24; x = 0; y = $script:my } }; $script:my++; return $p }
    # Collapsed row: nested panels are hidden until expanded, so per-service detail doesn't
    # visually duplicate the combined rows above it. Row itself only ever costs 1 grid unit.
    function MkCollapsedRow($t, $childPanels) { $script:mid++; $p = @{ id = $script:mid; type = 'row'; title = $t; collapsed = $true; panels = $childPanels; gridPos = @{ h = 1; w = 24; x = 0; y = $script:my } }; $script:my++; return $p }
    function MkStat($t, $e, $u, $x, $w) { $script:mid++; @{ id = $script:mid; type = 'stat'; title = $t; datasource = $null; targets = @(@{ expr = $e; legendFormat = ''; refId = 'A' }); fieldConfig = @{ defaults = @{ unit = $u } }; gridPos = @{ h = 4; w = $w; x = $x; y = $script:my } } }
    function MkGraph($t, $tg, $u, $x, $w, $h) { $script:mid++; @{ id = $script:mid; type = 'timeseries'; title = $t; datasource = $null; targets = $tg; fieldConfig = @{ defaults = @{ unit = $u; custom = @{ drawStyle = 'line'; lineWidth = 2; fillOpacity = 10 } } }; gridPos = @{ h = $h; w = $w; x = $x; y = $script:my } } }
    function MkTable($t, $e, $x, $w, $h) { $script:mid++; @{ id = $script:mid; type = 'table'; title = $t; datasource = $null; targets = @(@{ expr = $e; legendFormat = ''; refId = 'A'; instant = $true; format = 'table' }); gridPos = @{ h = $h; w = $w; x = $x; y = $script:my } } }

    # --- Overview ---
    $panels += MkRow 'Overview - All Services'
    $panels += MkStat 'Total Request Rate (req/min)' "sum(rate(http_requests_received_total{$all}[5m])) * 60" 'reqps' 0 4
    $panels += MkStat 'Active Requests Now' "sum(microsoft_aspnetcore_hosting_http_server_active_requests{$all}) or vector(0)" 'short' 4 4
    $panels += MkStat '5xx Error Rate (req/min)' "(sum(rate(http_requests_received_total{$all,code=~`"5..`"}[5m])) * 60) or vector(0)" 'short' 8 4
    $panels += MkStat '4xx Client Error Rate (req/min)' "(sum(rate(http_requests_received_total{$all,code=~`"4..`"}[5m])) * 60) or vector(0)" 'short' 12 4
    $panels += MkStat 'Success Rate %' "100 * sum(rate(http_requests_received_total{$all,code=~`"2..`"}[5m])) / sum(rate(http_requests_received_total{$all}[5m]))" 'percent' 16 4
    $panels += MkStat 'Total Requests (24h)' "sum(increase(http_requests_received_total{$all}[24h]))" 'short' 20 4
    $script:my += 4

    # --- Health ---
    $panels += MkRow 'Service Health & Availability'
    $x = 0
    foreach ($s in $Services) {
        $panels += MkStat $s.Display "min(up{$Label=`"$($s.Selector)`"}) or vector(0)" 'short' $x 3
        $x += 3
        if ($x -ge 24) { $x = 0; $script:my += 4 }
    }
    $panels += MkStat 'Avg Replica Uptime' "avg(time() - process_start_time_seconds{$ns$all}) or vector(0)" 's' $x 6
    $script:my += 4

    # --- Request rate ---
    $panels += MkRow 'Request Rate by Service'
    $panels += MkGraph 'Request Rate per Service (req/min)' @(@{ expr = "sum by ($Label) (rate(http_requests_received_total{$all}[5m])) * 60"; legendFormat = "{{$Label}}"; refId = 'A' }) 'reqps' 0 12 8
    $panels += MkGraph 'Response Status Code Distribution (req/min)' @(@{ expr = "sum by (code) (rate(http_requests_received_total{$all}[5m])) * 60"; legendFormat = '{{code}}'; refId = 'A' }) 'reqps' 12 12 8
    $script:my += 8

    if ($apiServices.Count -gt 0) {
        $apiSel = ($apiServices | ForEach-Object { [regex]::Escape($_.Selector) }) -join '|'
        $api = "$Label=~`"$apiSel`""

        $panels += MkRow 'API Endpoint Full Inventory'
        $panels += MkTable 'All API Endpoints - Inventory' "sort_desc(sum by ($Label, method, action, controller) (http_requests_received_total{$api, action!=`"`"}))" 0 24 10
        $script:my += 10
        $panels += MkGraph 'Top 20 API Actions by Request Volume' @(@{ expr = "topk(20, sum by (action) (http_requests_received_total{$api, action!=`"`"}))"; legendFormat = '{{action}}'; refId = 'A' }) 'short' 0 24 8
        $script:my += 8

        $panels += MkRow 'API Action Latency Analysis'
        $panels += MkTable 'API Action Latency Rankings - Avg Duration' "sort_desc(sum by ($Label, action) (http_request_duration_seconds_sum{$api, action!=`"`"}) / sum by ($Label, action) (http_request_duration_seconds_count{$api, action!=`"`"}))" 0 24 10
        $script:my += 10
        $panels += MkGraph 'Top 10 Slowest APIs - P95 Latency' @(@{ expr = "topk(10, histogram_quantile(0.95, sum by (action, le) (rate(http_request_duration_seconds_bucket{$api, action!=`"`"}[5m]))))"; legendFormat = '{{action}}'; refId = 'A' }) 's' 0 24 8
        $script:my += 8

        $panels += MkRow 'API Error Analysis by Action'
        $panels += MkTable 'API Action Error Breakdown (4xx/5xx)' "sort_desc(sum by ($Label, action, method, code) (http_requests_received_total{$api, action!=`"`", code!~`"2..`"}))" 0 24 10
        $script:my += 10
        $panels += MkGraph 'Error Rate Trend by API Action (req/min)' @(@{ expr = "sum by (action, code) (rate(http_requests_received_total{$api, action!=`"`", code!~`"2..`"}[5m])) * 60"; legendFormat = '{{action}} {{code}}'; refId = 'A' }) 'reqps' 0 24 8
        $script:my += 8

        $panels += MkRow 'API Success vs Failure Comparison'
        $panels += MkGraph 'Success Rate % by Service' @(@{ expr = "100 * sum by ($Label) (rate(http_requests_received_total{$api, code=~`"2..`"}[5m])) / sum by ($Label) (rate(http_requests_received_total{$api}[5m]))"; legendFormat = "{{$Label}}"; refId = 'A' }) 'percent' 0 12 8
        $panels += MkGraph 'Request Volume by Status Code per Service' @(
            @{ expr = "sum by ($Label) (rate(http_requests_received_total{$api, code=~`"2..`"}[5m])) * 60"; legendFormat = "2xx {{$Label}}"; refId = 'A' },
            @{ expr = "sum by ($Label) (rate(http_requests_received_total{$api, code=~`"4..`"}[5m])) * 60"; legendFormat = "4xx {{$Label}}"; refId = 'B' },
            @{ expr = "sum by ($Label) (rate(http_requests_received_total{$api, code=~`"5..`"}[5m])) * 60"; legendFormat = "5xx {{$Label}}"; refId = 'C' }
        ) 'reqps' 12 12 8
        $script:my += 8

        $panels += MkRow 'Top Endpoints - Most Used & Failures'
        $panels += MkTable 'Top 25 Most-Used API Endpoints' "topk(25, sum by (action, method, $Label) (rate(http_requests_received_total{$api, action!=`"`"}[5m])) * 60)" 0 12 10
        $panels += MkTable 'Top Failing Endpoints (4xx/5xx)' "topk(25, sum by (action, method, code, $Label) (rate(http_requests_received_total{$api, action!=`"`", code!~`"2..`"}[5m])) * 60)" 12 12 10
        $script:my += 10

        $panels += MkRow 'Most Used APIs - Usage Distribution by Service'
        $panels += MkTable 'Top API Actions - Request Count per Service' "sort_desc(sum by ($Label, action, method) (http_requests_received_total{$api, action!=`"`"}))" 0 12 10
        $panels += MkGraph 'Top 10 Most Used APIs (All Services)' @(@{ expr = "topk(10, sum by (action, method) (http_requests_received_total{$api, action!=`"`"}))"; legendFormat = '{{method}} {{action}}'; refId = 'A' }) 'short' 12 12 10
        $script:my += 10

        $panels += MkRow 'API Actions by Endpoint'
        $panels += MkGraph 'Request Rate by Endpoint (req/min)' @(@{ expr = "sum by ($Label, exported_endpoint) (rate(http_requests_received_total{$api, exported_endpoint!=`"/health`"}[5m])) * 60"; legendFormat = "{{$Label}} {{exported_endpoint}}"; refId = 'A' }) 'reqps' 0 12 8
        $panels += MkGraph 'P95 Latency by Endpoint' @(@{ expr = "histogram_quantile(0.95, sum by ($Label, exported_endpoint, le) (rate(http_request_duration_seconds_bucket{$api, exported_endpoint!=`"/health`"}[5m])))"; legendFormat = "{{$Label}} {{exported_endpoint}}"; refId = 'A' }) 's' 12 12 8
        $script:my += 8
    }

    # --- Latency ---
    $panels += MkRow 'Request Duration & Latency'
    $panels += MkGraph 'HTTP Request Duration P50 / P95 / P99 by Service' @(
        @{ expr = "histogram_quantile(0.5, sum by ($Label, le) (rate(http_request_duration_seconds_bucket{$all}[5m])))"; legendFormat = "P50 {{$Label}}"; refId = 'A' },
        @{ expr = "histogram_quantile(0.95, sum by ($Label, le) (rate(http_request_duration_seconds_bucket{$all}[5m])))"; legendFormat = "P95 {{$Label}}"; refId = 'B' },
        @{ expr = "histogram_quantile(0.99, sum by ($Label, le) (rate(http_request_duration_seconds_bucket{$all}[5m])))"; legendFormat = "P99 {{$Label}}"; refId = 'C' }
    ) 's' 0 12 8
    $panels += MkGraph 'ASP.NET Server Request Duration P95 by Service' @(@{ expr = "histogram_quantile(0.95, sum by ($Label, le) (rate(microsoft_aspnetcore_hosting_http_server_request_duration_bucket{$all}[5m])))"; legendFormat = "{{$Label}}"; refId = 'A' }) 's' 12 12 8
    $script:my += 8

    # --- PMDAL ---
    if ($pmdalServices.Count -gt 0) {
        $panels += MkRow 'PMDAL (Database) Processing Time'
        $dur = @(); $rate = @(); $i = 0
        foreach ($s in $pmdalServices) {
            $rid = [char](65 + $i)
            $dur  += @{ expr = "histogram_quantile(0.95, sum by (le) (rate($($s.PmdalPrefix)_HISTOGRAM_PMDAL_Processing_Time_bucket[5m])))"; legendFormat = $s.Display; refId = "$rid" }
            $rate += @{ expr = "sum(rate($($s.PmdalPrefix)_HISTOGRAM_PMDAL_Processing_Time_count[5m]))"; legendFormat = $s.Display; refId = "$rid" }
            $i++
        }
        $panels += MkGraph 'PMDAL Query Duration P95 by Service' $dur 's' 0 12 8
        $panels += MkGraph 'PMDAL Query Rate (ops/s) by Service' $rate 'ops' 12 12 8
        $script:my += 8
    }

    # --- Traffic patterns ---
    $panels += MkRow 'Daily Access & Traffic Patterns'
    $panels += MkGraph 'Hourly Request Volume by Service' @(@{ expr = "sum by ($Label) (increase(http_requests_received_total{$all}[1h]))"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 0 12 8
    $panels += MkGraph 'Hourly Error Volume by Service' @(@{ expr = "sum by ($Label) (increase(http_requests_received_total{$all, code!~`"2..`"}[1h]))"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 12 12 8
    $script:my += 8

    # Per-service API breakdown, collapsed by default so the real per-action detail is
    # available on drill-down without duplicating space on the combined overview rows.
    foreach ($s in $apiServices) {
        $one = "$Label=`"$($s.Selector)`""
        $childY = $script:my + 1
        $save = $script:my
        $script:my = $childY
        $children = @(
            (MkGraph "$($s.Display) - Request Rate by Action (req/min)" @(@{ expr = "sum by (action) (rate(http_requests_received_total{$one, action!=`"`"}[5m])) * 60"; legendFormat = '{{action}}'; refId = 'A' }) 'reqps' 0 8 8),
            (MkGraph "$($s.Display) - P95 Latency by Action" @(@{ expr = "histogram_quantile(0.95, sum by (action, le) (rate(http_request_duration_seconds_bucket{$one, action!=`"`"}[5m])))"; legendFormat = '{{action}}'; refId = 'A' }) 's' 8 8 8),
            (MkGraph "$($s.Display) - Errors by Action & Status" @(@{ expr = "sum by (action, code) (rate(http_requests_received_total{$one, action!=`"`", code!~`"2..`"}[5m])) * 60"; legendFormat = '{{action}} {{code}}'; refId = 'A' }) 'reqps' 16 8 8)
        )
        $script:my = $save
        $panels += MkCollapsedRow "$($s.Display) - API Action Detail" $children
    }

    # --- RabbitMQ ---
    if ($RabbitMQContainer) {
        $rmq = "$ns$RabbitMQLabel=`"$RabbitMQContainer`""
        $panels += MkRow 'RabbitMQ - Message Bus Health'
        $panels += MkStat 'Connections' "sum(rabbitmq_connections{$rmq})" 'short' 0 4
        $panels += MkStat 'Channels' "sum(rabbitmq_channels{$rmq})" 'short' 4 4
        $panels += MkStat 'Messages Ready' "sum(rabbitmq_queue_messages_ready{$rmq})" 'short' 8 4
        $panels += MkStat 'Messages Unacked' "sum(rabbitmq_queue_messages_unacked{$rmq})" 'short' 12 4
        $panels += MkStat 'Queue Consumers' "sum(rabbitmq_queue_consumers{$rmq})" 'short' 16 4
        $panels += MkStat 'Total Queues' "sum(rabbitmq_queues{$rmq})" 'short' 20 4
        $script:my += 4
        $panels += MkGraph 'Publish & Deliver Rate (msg/s)' @(
            @{ expr = "sum(rate(rabbitmq_queue_messages_published_total{$rmq}[5m]))"; legendFormat = 'Published'; refId = 'A' },
            @{ expr = "sum(rate(rabbitmq_queue_messages_delivered_total{$rmq}[5m]))"; legendFormat = 'Delivered'; refId = 'B' },
            @{ expr = "sum(rate(rabbitmq_queue_messages_acked_total{$rmq}[5m]))"; legendFormat = 'Acked'; refId = 'C' }
        ) 'ops' 0 12 8
        $panels += MkGraph 'Queue Depth by Queue' @(@{ expr = "sum by (queue) (rabbitmq_queue_messages_ready{$rmq})"; legendFormat = '{{queue}}'; refId = 'A' }) 'short' 12 12 8
        $script:my += 8

        # Real per-service attribution, only once the app itself tags its own usage -
        # the broker metrics above never carry a per-service dimension.
        if ($RabbitMQServiceMetric) {
            $panels += MkGraph 'RabbitMQ Usage by Service (msg/min)' @(@{ expr = "sum by (service) (rate($RabbitMQServiceMetric[5m])) * 60"; legendFormat = '{{service}}'; refId = 'A' }) 'reqps' 0 24 8
            $script:my += 8
        }
    }

    # --- Redis ---
    if ($RedisInstance) {
        $rds = "$ns$RedisLabel=`"$RedisInstance`""
        $panels += MkRow 'Redis Cache Performance'
        $panels += MkStat 'Cache Hit Rate %' "100 * sum(rate(redis_keyspace_hits_total{$rds}[5m])) / clamp_min(sum(rate(redis_keyspace_hits_total{$rds}[5m])) + sum(rate(redis_keyspace_misses_total{$rds}[5m])), 0.000001)" 'percent' 0 6
        $panels += MkStat 'Connected Clients' "sum(redis_connected_clients{$rds})" 'short' 6 6
        $panels += MkStat 'Memory Used' "sum(redis_memory_used_bytes{$rds})" 'bytes' 12 6
        $panels += MkStat 'DB Keys' "sum(redis_db_keys{$rds})" 'short' 18 6
        $script:my += 4
        $panels += MkGraph 'Redis Operations Rate (ops/s)' @(@{ expr = "sum(rate(redis_commands_processed_total{$rds}[5m]))"; legendFormat = 'Commands'; refId = 'A' }) 'ops' 0 12 8
        $panels += MkGraph 'Redis Hit / Miss Rate' @(
            @{ expr = "sum(rate(redis_keyspace_hits_total{$rds}[5m]))"; legendFormat = 'Hits'; refId = 'A' },
            @{ expr = "sum(rate(redis_keyspace_misses_total{$rds}[5m]))"; legendFormat = 'Misses'; refId = 'B' }
        ) 'ops' 12 12 8
        $script:my += 8

        # Real per-service attribution, only once the app itself tags its own usage -
        # the exporter metrics above never carry a per-service dimension.
        if ($RedisServiceMetric) {
            $panels += MkGraph 'Redis Usage by Service (ops/min)' @(@{ expr = "sum by (service) (rate($RedisServiceMetric[5m])) * 60"; legendFormat = '{{service}}'; refId = 'A' }) 'reqps' 0 24 8
            $script:my += 8
        }
    }

    # --- Auth ---
    $panels += MkRow 'Authentication & Security'
    $authTargets = @(@{ expr = "sum by ($Label) (rate(http_requests_received_total{$all, code=`"401`"}[5m])) * 60"; legendFormat = "401 {{$Label}}"; refId = 'A' })
    $panels += MkGraph 'Authentication Errors (401) per Service (req/min)' $authTargets 'reqps' 0 12 8
    if ($AuthMetric) {
        $panels += MkGraph 'Auth Requests by Scheme (req/min)' @(@{ expr = "sum by (scheme) (rate($AuthMetric{$all}[5m])) * 60"; legendFormat = '{{scheme}}'; refId = 'A' }) 'reqps' 12 12 8
        $script:my += 8

        $panels += MkRow 'Authentication - Scheme Traffic Comparison'
        $panels += MkGraph 'Auth Requests by Service & Scheme (req/min)' @(@{ expr = "sum by ($Label, scheme) (rate($AuthMetric{$all}[5m])) * 60"; legendFormat = "{{$Label}} {{scheme}}"; refId = 'A' }) 'reqps' 0 24 8
        $script:my += 8
        $panels += MkStat 'Total Authenticated (24h)' "sum(increase($AuthMetric{$all}[24h])) or vector(0)" 'short' 0 6
        $panels += MkStat '401 Failures (5m)' "(sum(rate(http_requests_received_total{$all,code=`"401`"}[5m])) * 300) or vector(0)" 'short' 6 6
        $panels += MkStat 'Auth Schemes In Use' "count(count by (scheme) ($AuthMetric{$all}))" 'short' 12 6
        $panels += MkStat 'Busiest Scheme (24h)' "max(sum by (scheme) (increase($AuthMetric{$all}[24h]))) or vector(0)" 'short' 18 6
        $script:my += 4
        $panels += MkTable 'Top 25 Most Called APIs - All Clients' "topk(25, sum by ($Label, action, method, code) (http_requests_received_total{$all, action!=`"`"}))" 0 24 10
        $script:my += 10
    }
    else { $script:my += 8 }

    # --- Resources ---
    $panels += MkRow 'Resource Usage (CPU / Memory / Connections)'
    $panels += MkGraph 'CPU Usage by Service' @(@{ expr = "sum by ($Label) (rate(process_cpu_seconds_total{$all}[5m]))"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 0 8 8
    $panels += MkGraph 'Memory Working Set by Service' @(@{ expr = "sum by ($Label) (process_working_set_bytes{$all})"; legendFormat = "{{$Label}}"; refId = 'A' }) 'bytes' 8 8 8
    $panels += MkGraph 'Open Handles' @(@{ expr = "sum by ($Label) (process_open_handles{$all})"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 16 8 8
    $script:my += 8

    # --- .NET runtime ---
    $panels += MkRow '.NET Runtime - GC / Threads / Exceptions'
    $panels += MkGraph 'GC Collections (per min)' @(@{ expr = "sum by ($Label) (rate(system_runtime_dotnet_gc_collections{$all}[5m])) * 60"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 0 8 8
    $panels += MkGraph 'Thread Pool Thread Count' @(@{ expr = "sum by ($Label) (system_runtime_dotnet_thread_pool_thread_count{$all})"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 8 8 8
    $panels += MkGraph '.NET Exceptions (per min)' @(@{ expr = "sum by ($Label) (rate(system_runtime_dotnet_exceptions{$all}[5m])) * 60"; legendFormat = "{{$Label}}"; refId = 'A' }) 'short' 16 8 8
    $script:my += 8

    # --- Pod health ---
    $panels += MkRow 'Pod Health - Restarts, Failures & Availability'
    $x = 0
    foreach ($s in $Services) {
        $panels += MkStat "Restarts - $($s.Display)" "sum(kube_pod_container_status_restarts_total{container=`"$($s.Chart)`"}) or vector(0)" 'short' $x 4
        $x += 4
        if ($x -ge 24) { $x = 0; $script:my += 4 }
    }
    $script:my += 4
    $panels += MkGraph 'Service Process Uptime (seconds)' @(@{ expr = "time() - process_start_time_seconds{$ns$all}"; legendFormat = "{{$Label}}"; refId = 'A' }) 's' 0 12 8
    $panels += MkGraph '5xx Server Errors Over Time' @(@{ expr = "sum by ($Label) (rate(http_requests_received_total{$all,code=~`"5..`"}[5m])) * 60"; legendFormat = "{{$Label}}"; refId = 'A' }) 'reqps' 12 12 8
    $script:my += 8

    # --- Client traffic ---
    if ($ClientMetric) {
        $panels += MkRow 'Client Traffic - Per-Site API Usage'
        $panels += MkGraph 'API Hits by Client Site (req/min)' @(@{ expr = "topk(10, sum by (site) (rate($ClientMetric{$all, site!=`"unknown`"}[5m])) * 60)"; legendFormat = '{{site}}'; refId = 'A' }) 'reqps' 0 12 8
        $panels += MkGraph 'API Hits by Site + Endpoint (req/min)' @(@{ expr = "topk(20, sum by (site, endpoint) (rate($ClientMetric{$all, site!=`"unknown`"}[5m])) * 60)"; legendFormat = '{{site}} {{endpoint}}'; refId = 'A' }) 'reqps' 12 12 8
        $script:my += 8
        $panels += MkStat 'Total Client API Hits (24h)' "sum(increase($ClientMetric{$all, site!=`"unknown`"}[24h]))" 'short' 0 6
        $panels += MkStat 'Active Sites (Clients)' "count(count by (site) ($ClientMetric{$all, site!=`"unknown`"}))" 'short' 6 6
        $panels += MkStat 'Most Active Site' "topk(1, sum by (site) (rate($ClientMetric{$all, site!=`"unknown`"}[5m])))" 'short' 12 6
        $panels += MkStat 'Unique Endpoints (24h)' "count(count by (endpoint) ($ClientMetric{$all, site!=`"unknown`"}))" 'short' 18 6
        $script:my += 4
        $panels += MkTable 'Client API Usage - Site x Endpoint x Method' "sort_desc(sum by (site, endpoint, method) ($ClientMetric{$all, site!=`"unknown`"}))" 0 24 10
        $script:my += 10
    }

    $dashboard = @{
        id = $null; uid = $Uid; title = $Title
        tags = @('kubernetes', 'auto-generated', 'overview')
        timezone = 'browser'; schemaVersion = 39; version = 1; refresh = '30s'
        time = @{ from = 'now-6h'; to = 'now' }
        editable = $true
        panels = $panels
        templating = @{ list = @(
            @{ name = 'service'; type = 'query'; includeAll = $true; multi = $true; refresh = 1
               query = "label_values(http_requests_received_total{$all}, $Label)" }
        ) }
        annotations = @{ list = @() }
    }

    [System.IO.File]::WriteAllText($OutputPath, ($dashboard | ConvertTo-Json -Depth 100 -Compress))
    return $panels.Count
}


# Service overrides layer on top of the shared defaults, so a service only declares what differs.
function Resolve-Feature {
    param($ChartName)

    $merged = [ordered]@{}
    foreach ($p in $defaults.features.PSObject.Properties) { $merged[$p.Name] = $p.Value }

    $ov = $config.overrides.$ChartName
    if ($ov -and $ov.features) {
        foreach ($p in $ov.features.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    return [pscustomobject]$merged
}

function Get-DisplayName {    param([string]$ChartName)

    $override = $config.overrides.$ChartName
    if ($override -and $override.displayName) { return $override.displayName }

    $core = $ChartName -replace '[-_]', ' '
    $core = $core -replace 'svc$', ''
    $core = $core.Trim()
    if (-not $core) { $core = $ChartName }
    $titled = (Get-Culture).TextInfo.ToTitleCase($core)
    return "$titled Service"
}

# Locate an existing dashboard that already queries this service, regardless of its file name.
# Multi-service dashboards also reference the selector, so prefer the dashboard dedicated to it.
function Find-ExistingDashboard {
    param([string]$Directory, [string]$SelectorValue)

    if (-not (Test-Path $Directory)) { return $null }

    $candidates = @()

    foreach ($file in Get-ChildItem $Directory -Filter *.json -File) {
        try {
            $json = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch { continue }

        $expressions = @()
        foreach ($panel in @($json.panels)) {
            foreach ($target in @($panel.targets)) {
                if ($target.expr) { $expressions += $target.expr }
            }
        }
        if ($expressions.Count -eq 0) { continue }

        $joined = $expressions -join ' '
        if ($joined -notmatch "=`"$([regex]::Escape($SelectorValue))`"") { continue }

        $distinct = @([regex]::Matches($joined, "$([regex]::Escape($SelectorLabel))=`"([^`"]+)`"") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

        $candidates += [pscustomobject]@{
            Path        = $file.FullName
            Name        = $file.Name
            Uid         = $json.uid
            Title       = $json.title
            PanelCount  = @($json.panels).Count
            ServiceSpan = [Math]::Max($distinct.Count, 1)
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object ServiceSpan, Name | Select-Object -First 1)
}

# The generator emits container="<value>"; retarget it to the label the chart's dashboards use.
function Set-DashboardIdentity {
    param(
        [string]$Path,
        [string]$GeneratedSelector,
        [string]$SelectorValue,
        [string]$Uid,
        [string]$Title,
        [object[]]$ExtraMetrics,
        [string]$ExtraTitle
    )

    $raw = Get-Content $Path -Raw -Encoding UTF8
    $raw = $raw.Replace("container=\`"$GeneratedSelector\`"", "$SelectorLabel=\`"$SelectorValue\`"")
    $dashboard = $raw | ConvertFrom-Json

    if ($Uid) { $dashboard.uid = $Uid }
    if ($Title) { $dashboard.title = $Title }

    $panels = @($dashboard.panels)
    $addedCount = 0

    if ($ExtraMetrics -and $ExtraMetrics.Count -gt 0) {
        $nextId = 1
        $nextY = 0
        foreach ($panel in $panels) {
            if ($panel.id -ge $nextId) { $nextId = [int]$panel.id + 1 }
            $bottom = [int]$panel.gridPos.y + [int]$panel.gridPos.h
            if ($bottom -gt $nextY) { $nextY = $bottom }
        }

        $added = @()
        $added += [ordered]@{
            id = $nextId; type = 'row'; title = $ExtraTitle; collapsed = $false
            panels = @(); gridPos = [ordered]@{ h = 1; w = 24; x = 0; y = $nextY }
        }
        $nextId++
        $nextY++

        $x = 0
        foreach ($metric in $ExtraMetrics) {
            $type = if ($metric.type) { $metric.type } else { 'timeseries' }
            $unit = if ($metric.unit) { $metric.unit } else { 'short' }
            $legend = if ($metric.legend) { $metric.legend } else { '' }
            $width = if ($type -eq 'stat') { 6 } else { 12 }
            $height = if ($type -eq 'stat') { 4 } else { 8 }
            if ($x + $width -gt 24) { $x = 0; $nextY += $height }

            $added += [ordered]@{
                id = $nextId; type = $type; title = $metric.title; datasource = $null
                targets = @([ordered]@{ expr = $metric.expr; legendFormat = $legend; refId = 'A' })
                fieldConfig = [ordered]@{ defaults = [ordered]@{ unit = $unit } }
                gridPos = [ordered]@{ h = $height; w = $width; x = $x; y = $nextY }
            }
            $nextId++
            $x += $width
        }

        $panels = @($panels + $added)
        $addedCount = $added.Count - 1
    }

    $dashboard.panels = $panels
    [System.IO.File]::WriteAllText($Path, ($dashboard | ConvertTo-Json -Depth 100 -Compress))

    return [pscustomobject]@{ ExtraPanels = $addedCount; PanelCount = $panels.Count }
}

# --- Resolve chart folder ---
if (-not $ChartPath) {
    $ChartPath = if ($Mode -eq 'Standalone') { $defaults.standaloneChartPath } else { $defaults.umbrellaChartPath }
}
if (-not (Test-Path $ChartPath)) {
    Write-Host "ERROR: Chart folder not found: $ChartPath" -ForegroundColor Red
    exit 1
}

$valuesPath = Join-Path $ChartPath 'values.yaml'

# ChartPath may be a single chart, or a folder holding several charts (e.g. repo\charts).
$isChartContainer = $false
if (-not (Test-Path $valuesPath)) {
    $childCharts = @(Get-ChildItem $ChartPath -Directory -EA SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'Chart.yaml')) -or (Test-Path (Join-Path $_.FullName 'values.yaml')) })

    if ($childCharts.Count -eq 0) {
        Write-Host "ERROR: No values.yaml and no charts found in: $ChartPath" -ForegroundColor Red
        exit 1
    }
    $isChartContainer = $true
}

$chartYaml = Join-Path $ChartPath 'Chart.yaml'
$chartDisplay = if (Test-Path $chartYaml) {
    $nameLine = Select-String -Path $chartYaml -Pattern '^\s*name:\s*(.+)$' | Select-Object -First 1
    if ($nameLine) { $nameLine.Matches[0].Groups[1].Value.Trim() } else { Split-Path $ChartPath -Leaf }
}
else { Split-Path $ChartPath -Leaf }

$defaultDashboardDir = Join-Path $ChartPath $defaults.dashboardSubPath

$discovered = @()
if (Test-Path $valuesPath) { $discovered = @(Get-ChartService -ValuesPath $valuesPath) }

# Subchart folders name services that values.yaml may not declare.
$subchartRoot = if ($isChartContainer) { $ChartPath } else { Join-Path $ChartPath 'charts' }
foreach ($sub in Get-SubchartService -SubchartRoot $subchartRoot -PerChartDashboard:$isChartContainer) {
    if (-not ($discovered | Where-Object { $_.ChartName -eq $sub.ChartName })) {
        $discovered += $sub
    }
}

# A standalone chart has no per-service blocks, so the chart itself is the service.
if ($discovered.Count -eq 0) {
    $fallbackSelector = if ($SelectorValue) { $SelectorValue } elseif ($Service) { $Service } else { $chartDisplay }
    $discovered = @([pscustomobject]@{
        ChartName     = $chartDisplay
        SelectorValue = $fallbackSelector
        Namespace     = ''
    })
}

if (-not $Mode) { $Mode = if ($discovered.Count -gt 1) { 'Umbrella' } else { 'Standalone' } }

Write-Host "`n========================================" -ForegroundColor Gray
Write-Host "  Service Dashboard Generator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Gray
Write-Host "Chart folder  : $ChartPath"
Write-Host "Chart name    : $chartDisplay"
Write-Host "Mode          : $Mode"
Write-Host "Dashboard dir : $(if ($DashboardDir) { $DashboardDir } elseif ($isChartContainer) { 'per-chart <chart>\' + $defaults.dashboardSubPath } else { $defaultDashboardDir })"
Write-Host "Selector      : $SelectorLabel"
Write-Host "Services found: $($discovered.Count) ($((($discovered.ChartName) -join ', ')))"
if ($DryRun) { Write-Host "*** DRY RUN - nothing will be written ***" -ForegroundColor Yellow }

$targets = @()
if ($Service) {
    $targets = @($discovered | Where-Object { $_.ChartName -eq $Service })
    if ($targets.Count -eq 0) {
        Write-Host "`nERROR: '$Service' not found in $valuesPath" -ForegroundColor Red
        Write-Host "Available: $((($discovered.ChartName) -join ', '))"
        exit 1
    }
}
elseif ($All) {
    $targets = $discovered
}
else {
    Write-Host "`nERROR: Specify -Service <chartName> or -All." -ForegroundColor Red
    Write-Host "Available: $((($discovered.ChartName) -join ', '))"
    exit 1
}

$created = 0
$updated = 0
$skipped = 0
$failed = 0
$unmatched = 0

$knownSelectors = $null
if ($PrometheusUrl) {
    Write-Host "`nValidating selectors against Prometheus: $PrometheusUrl" -ForegroundColor Cyan
    $knownSelectors = Get-PrometheusLabelValue -BaseUrl $PrometheusUrl -Label $SelectorLabel
    if ($knownSelectors) {
        Write-Host "  Found $($knownSelectors.Count) '$SelectorLabel' value(s) in Prometheus."
    }
}

foreach ($svc in $targets) {
    $chartName = $svc.ChartName
    $svcSelector = if ($SelectorValue) { $SelectorValue } elseif ($svc.SelectorValue) { $svc.SelectorValue } else { $chartName }
    $override = $config.overrides.$chartName
    $displayName = Get-DisplayName -ChartName $chartName
    $ns = if ($Namespace) { $Namespace } elseif ($svc.Namespace) { $svc.Namespace } else { $defaults.namespace }

    $svcDashboardDir = if ($DashboardDir) { $DashboardDir }
                       elseif ($svc.DashboardDir) { $svc.DashboardDir }
                       else { $defaultDashboardDir }

    Write-Host "`n--- $chartName ---" -ForegroundColor Cyan
    Write-Host "  Selector : $SelectorLabel=`"$svcSelector`""
    Write-Host "  Namespace: $ns"

    $repoPath = if ($override -and $override.repoPath) { $override.repoPath } elseif ($ServiceRepoPath) { $ServiceRepoPath } else { $null }
    $validation = if ($repoPath) { Test-ServiceRepository -RepoPath $repoPath } else { $null }
    if ($validation) { Write-ServiceValidation -Validation $validation }

    if ($knownSelectors) {
        if ($knownSelectors -contains $svcSelector) {
            Write-Host "  Prometheus: MATCH" -ForegroundColor Green
        }
        else {
            $unmatched++
            $near = @($knownSelectors | Where-Object { $_ -like "*$chartName*" -or $svcSelector -like "*$_*" }) | Select-Object -First 3
            Write-Host "  Prometheus: NO MATCH - this dashboard will show no data" -ForegroundColor Red
            if ($near) { Write-Host "              closest: $($near -join ', ')" -ForegroundColor Yellow }
        }
    }

    $existing = Find-ExistingDashboard -Directory $svcDashboardDir -SelectorValue $svcSelector

    if ($existing -and $Force) {
        Write-Host "  Action   : OVERWRITE (-Force)" -ForegroundColor Yellow
        Write-Host "  File     : $($existing.Name)"
        Write-Host "  Uid      : $($existing.Uid)  (preserved)"
        Write-Host "  Title    : $($existing.Title)  (preserved)"
        Write-Host "  Panels   : $($existing.PanelCount) existing"
    }
    elseif ($existing) {
        Write-Host "  Action   : CREATE NEW (existing file left untouched)" -ForegroundColor Green
        Write-Host "  Existing : $($existing.Name)  ($($existing.PanelCount) panels, uid $($existing.Uid))"
        Write-Host "  New file : $(Split-Path (Get-FreeDashboardPath -Directory $svcDashboardDir -BaseName "$displayName Dashboard") -Leaf)"
    }
    else {
        Write-Host "  Action   : CREATE" -ForegroundColor Green
        Write-Host "  File     : $displayName Dashboard.json"
    }

    if ($DryRun) { continue }

    try {
        if (-not (Test-Path $svcDashboardDir)) {
            New-Item -ItemType Directory -Path $svcDashboardDir -Force | Out-Null
        }

        $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("dash-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        $params = @{
            ServiceName   = $displayName
            ContainerName = $svcSelector
            JobName       = $svcSelector
            Namespace     = $ns
            OutputDir     = $staging
        }

        $features = Resolve-Feature -ChartName $chartName

        # Repo evidence narrows what's even considered before Prometheus is asked for proof.
        # No DAL -> no PMDAL section, silently. DAL with no instrumentation -> a real gap.
        if ($validation) {
            if (-not $validation.Dal) { $features.pmdal = $false }
            elseif ($validation.PmdalPrefix -and -not $features.pmdalPrefix) { $features.pmdalPrefix = $validation.PmdalPrefix }
            elseif ($features.pmdal -and -not $features.pmdalPrefix) {
                Write-InstrumentationGap -Kind 'pmdal' -MetricName $chartName.ToUpper() -LabelFilter ''
                $features.pmdal = $false
            }

            if (-not $validation.MetricsCode) {
                $features.auth = $false
                $features.clients = $false
            }
            else {
                if ($validation.AuthMetric -and -not $features.authMetric) { $features.authMetric = $validation.AuthMetric }
                if ($validation.ClientMetric -and -not $features.clientMetric) { $features.clientMetric = $validation.ClientMetric }
                if ($validation.HasAuthUsage -and $features.auth -and -not $features.authMetric) {
                    Write-InstrumentationGap -Kind 'auth' -MetricName "${chartName}_auth_validations_total" -LabelFilter ''
                    $features.auth = $false
                }
            }

            if ($validation.UsesRabbitMQ -and -not $validation.AppRabbitMetric -and -not $features.rabbitmqServiceMetric) {
                Write-InstrumentationGap -Kind 'rabbitmq-service' -MetricName "${chartName}_rabbitmq_messages_total" -LabelFilter ''
            }
            if ($validation.UsesRedis -and -not $validation.AppRedisMetric -and -not $features.redisServiceMetric) {
                Write-InstrumentationGap -Kind 'redis-service' -MetricName "${chartName}_redis_ops_total" -LabelFilter ''
            }
        }

        # Skip components that are configured but have no real data for this service -
        # keeps per-service dashboards accurate instead of shipping empty panels.
        if ($PrometheusUrl) {
            if ($features.auth -and $features.authMetric) {
                $exists = Test-PrometheusSeriesExists -BaseUrl $PrometheusUrl -Query "$($features.authMetric){$SelectorLabel=`"$svcSelector`"}"
                if ($exists -eq $false) { Write-InstrumentationGap -Kind 'auth' -MetricName $features.authMetric -LabelFilter "$SelectorLabel=`"$svcSelector`""; $features.auth = $false }
            }
            if ($features.clients -and $features.clientMetric) {
                $exists = Test-PrometheusSeriesExists -BaseUrl $PrometheusUrl -Query "$($features.clientMetric){$SelectorLabel=`"$svcSelector`"}"
                if ($exists -eq $false) { Write-InstrumentationGap -Kind 'clients' -MetricName $features.clientMetric -LabelFilter "$SelectorLabel=`"$svcSelector`""; $features.clients = $false }
            }
            if ($features.pmdal -and $features.pmdalPrefix) {
                $exists = Test-PrometheusSeriesExists -BaseUrl $PrometheusUrl -Query "$($features.pmdalPrefix)_HISTOGRAM_PMDAL_Processing_Time_count"
                if ($exists -eq $false) { Write-InstrumentationGap -Kind 'pmdal' -MetricName $features.pmdalPrefix -LabelFilter ''; $features.pmdal = $false }
            }
        }

        # RabbitMQ/Redis are shared cluster infra (one broker, one cache) - they belong only
        # on the main overview dashboard, not duplicated into every per-service dashboard.
        if ($features.clients -and $features.clientMetric) {
            $params.IncludeClientMetric = $true
            $params.ClientMetric = $features.clientMetric
        }
        if ($features.auth -and $features.authMetric) {
            $params.IncludeAuthMetric = $true
            $params.AuthMetric = $features.authMetric
            if ($features.authPrimaryScheme)   { $params.AuthPrimaryScheme = $features.authPrimaryScheme }
            if ($features.authSecondaryScheme) { $params.AuthSecondaryScheme = $features.authSecondaryScheme }
        }
        if ($features.pmdal) {
            $params.IncludePMDAL = $true
            if ($features.pmdalPrefix) { $params.PMDALPrefix = $features.pmdalPrefix }
        }
        if ($null -ne $features.api) { $params.IncludeApiDetail = [bool]$features.api }

        $staged = & $generator @params

        $extraMetrics = if ($override -and $override.extraMetrics) { @($override.extraMetrics) } else { @() }
        $result = Set-DashboardIdentity -Path $staged `
            -GeneratedSelector $svcSelector `
            -SelectorValue $svcSelector `
            -Uid $(if ($existing -and $Force) { $existing.Uid } else { $null }) `
            -Title $(if ($existing -and $Force) { $existing.Title } else { $null }) `
            -ExtraMetrics $extraMetrics `
            -ExtraTitle "Additional Metrics - $displayName"

        if ($existing -and $Force) {
            Copy-Item $existing.Path "$($existing.Path).bak" -Force
            Move-Item $staged $existing.Path -Force
            Write-Host "  Written  : $($existing.Name) ($($result.PanelCount) panels, backup .bak created)" -ForegroundColor Green
            $updated++
        }
        else {
            $destination = Get-FreeDashboardPath -Directory $svcDashboardDir -BaseName "$displayName Dashboard"
            Move-Item $staged $destination -Force
            Write-Host "  Written  : $(Split-Path $destination -Leaf) ($($result.PanelCount) panels)" -ForegroundColor Green
            if ($existing) {
                Write-Host "  Kept     : $($existing.Name) unchanged - compare, then delete the one you do not want" -ForegroundColor Cyan
            }
            $created++
        }

        if ($result.ExtraPanels -gt 0) {
            Write-Host "  Extra    : $($result.ExtraPanels) additional metric panel(s)" -ForegroundColor Green
        }

        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        $failed++
        Write-Host "  FAILED   : $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($IncludeMain) {
    Write-Host "`n--- Main overview dashboard ---" -ForegroundColor Cyan

    $mainServices = @($discovered | ForEach-Object {
        $sel = if ($SelectorValue) { $SelectorValue } elseif ($_.SelectorValue) { $_.SelectorValue } else { $_.ChartName }
        $ov = $config.overrides.($_.ChartName)
        $feat = Resolve-Feature -ChartName $_.ChartName
        [pscustomobject]@{
            Chart       = $_.ChartName
            Selector    = $sel
            Display     = (Get-DisplayName -ChartName $_.ChartName) -replace ' Service$', ''
            HasApi      = if ($null -ne $feat.api) { [bool]$feat.api } else { $true }
            PmdalPrefix = if ($feat.pmdal) { $feat.pmdalPrefix } else { $null }
        }
    })

    $mainDir = if ($DashboardDir) { $DashboardDir } else { $defaultDashboardDir }
    $title = if ($MainTitle) { $MainTitle } else { "$chartDisplay Operations Dashboard" }
    $mainUid = (($title -replace '[^a-zA-Z0-9]', '-') -replace '-+', '-').ToLower().Trim('-')

    Write-Host "  Services : $($mainServices.Count) ($((($mainServices.Selector) -join ', ')))"
    Write-Host "  Title    : $title"

    if ($DryRun) {
        Write-Host "  [DRY RUN] Overview dashboard not generated." -ForegroundColor Yellow
    }
    else {
        try {
            if (-not (Test-Path $mainDir)) { New-Item -ItemType Directory -Path $mainDir -Force | Out-Null }

            $common = Resolve-Feature -ChartName ($discovered[0].ChartName)
            $clientMetric = if ($common.clients) { $common.clientMetric } else { $null }
            $authMetric   = if ($common.auth)    { $common.authMetric }   else { $null }
            $rmqContainer = if ($common.rabbitmq) { $common.rabbitmqContainer } else { $null }
            $rmqLabel     = if ($common.rabbitmqLabel) { $common.rabbitmqLabel } else { 'job' }
            $redisInst    = if ($common.redis) { $common.redisInstance } else { $null }
            $redisLabel   = if ($common.redisLabel) { $common.redisLabel } else { 'job' }
            $rmqSvcMetric   = $common.rabbitmqServiceMetric
            $redisSvcMetric = $common.redisServiceMetric

            # Shared infra rows only render when the broker/cache is actually reachable.
            if ($PrometheusUrl) {
                if ($rmqContainer) {
                    $exists = Test-PrometheusSeriesExists -BaseUrl $PrometheusUrl -Query "rabbitmq_queue_messages_ready{$rmqLabel=`"$rmqContainer`"}"
                    if ($exists -eq $false) { Write-InstrumentationGap -Kind 'rabbitmq' -MetricName 'rabbitmq_queue_messages_ready' -LabelFilter "$rmqLabel=`"$rmqContainer`""; $rmqContainer = $null }
                }
                if ($redisInst) {
                    $exists = Test-PrometheusSeriesExists -BaseUrl $PrometheusUrl -Query "redis_memory_used_bytes{$redisLabel=`"$redisInst`"}"
                    if ($exists -eq $false) { Write-InstrumentationGap -Kind 'redis' -MetricName 'redis_memory_used_bytes' -LabelFilter "$redisLabel=`"$redisInst`""; $redisInst = $null }
                }
            }

            $mainNs = if ($Namespace) { $Namespace } else { ($discovered | Where-Object { $_.Namespace } | Select-Object -First 1).Namespace }

            $mainPath = Get-FreeDashboardPath -Directory $mainDir -BaseName $title
            $count = New-MainDashboard -Services $mainServices -Label $SelectorLabel -Title $title -Uid $mainUid `
                -OutputPath $mainPath -Namespace $mainNs -ClientMetric $clientMetric -AuthMetric $authMetric `
                -RabbitMQContainer $rmqContainer -RabbitMQLabel $rmqLabel -RabbitMQServiceMetric $rmqSvcMetric `
                -RedisInstance $redisInst -RedisLabel $redisLabel -RedisServiceMetric $redisSvcMetric

            Write-Host "  Written  : $(Split-Path $mainPath -Leaf) ($count panels)" -ForegroundColor Green
            $created++
        }
        catch {
            $failed++
            Write-Host "  FAILED   : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host "`n========================================" -ForegroundColor Gray
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Gray
Write-Host "Processed : $($targets.Count)"
Write-Host "Created   : $created"
Write-Host "Updated   : $updated"
Write-Host "Skipped   : $skipped"
Write-Host "Failed    : $failed"
if ($knownSelectors) { Write-Host "Unmatched : $unmatched (selector not present in Prometheus)" }

if ($failed -gt 0) { exit 1 }

