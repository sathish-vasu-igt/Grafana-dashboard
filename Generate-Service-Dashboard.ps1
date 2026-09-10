<#
.SYNOPSIS
    Generate Grafana dashboards for any Kubernetes service with Prometheus metrics.
.DESCRIPTION
    Creates a comprehensive Grafana dashboard JSON for any service running in Kubernetes.
    Tracks: Request rate, latency, errors, status codes, top endpoints, resource usage,
    health status, and auth scheme breakdown.

    Designed for services that expose prometheus-net metrics at /metrics endpoint.
.PARAMETER ServiceName
    Display name for the dashboard (e.g., "Player Ops Service")
.PARAMETER ContainerName
    Kubernetes container name as seen in Prometheus (e.g., "playeropssvc")
.PARAMETER JobName
    Prometheus job name. Defaults to the container name if not specified.
.PARAMETER Namespace
    Kubernetes namespace (default: "igt-floornet")
.PARAMETER OutputDir
    Output directory for the dashboard JSON (default: current directory)
.PARAMETER DashboardUID
    Grafana dashboard UID (auto-generated if not specified)
.PARAMETER IncludeAuthMetric
    Include auth scheme breakdown panels. Requires -AuthMetric.
.PARAMETER AuthMetric
    Counter metric holding auth requests, with scheme/issuer labels.
.PARAMETER AuthPrimaryScheme
    Optional scheme label value to chart as the primary auth path.
.PARAMETER AuthSecondaryScheme
    Optional scheme label value to compare against the primary.
.PARAMETER IncludePMDAL
    Include database query duration panels (requires <PMDALPrefix>_HISTOGRAM_PMDAL_* metrics)
.PARAMETER PMDALPrefix
    Database histogram metric prefix.
.PARAMETER IncludeRabbitMQ
    Include RabbitMQ broker panels. Requires -RabbitMQContainer.
.PARAMETER RabbitMQContainer
    Label value identifying the RabbitMQ broker exporter.
.PARAMETER RabbitMQLabel
    Label name carrying the broker identity (default: job).
.PARAMETER IncludeClientMetric
    Include per-client usage panels. Requires -ClientMetric.
.PARAMETER ClientMetric
    Counter of API hits per client, expected to carry site/endpoint/method labels.
.PARAMETER IncludeRedis
    Include Redis panels.
.PARAMETER RedisInstance
    Optional label value scoping Redis panels to one instance.
.PARAMETER RedisLabel
    Label name carrying the Redis instance identity (default: job).
.PARAMETER IncludeRedis
    Include Redis panels (requires redis_* metrics)
.PARAMETER Minify
    Minify output JSON (default: true)
.EXAMPLE
    # Generate dashboard for a single service
    .\Generate-Service-Dashboard.ps1 -ServiceName "Player Ops Service" -ContainerName "playeropssvc"

    # Generate with optional feature rows
    .\Generate-Service-Dashboard.ps1 -ServiceName "Buckets Balances" -ContainerName "bucketsbalancessvc" `
        -IncludeAuthMetric -AuthMetric "myapp_auth_requests_total" `
        -IncludePMDAL -PMDALPrefix "MYAPP_BucketsBalancesSvc" `
        -IncludeRabbitMQ -RabbitMQContainer "my-rabbitmq" -IncludeRedis

    # Generate for a service in another namespace
    .\Generate-Service-Dashboard.ps1 -ServiceName "Payment Gateway" -ContainerName "payment-gateway-svc" `
        -Namespace "payments" -JobName "payment-gateway"

    # Batch generate for multiple services
    $services = @(
        @{ Name="Auth Service"; Container="auth-svc" },
        @{ Name="Notification Service"; Container="notify-svc" },
        @{ Name="Audit Service"; Container="audit-svc" }
    )
    $services | ForEach-Object { .\Generate-Service-Dashboard.ps1 -ServiceName $_.Name -ContainerName $_.Container }
#>

param(
    [Parameter(Mandatory)][string]$ServiceName,
    [Parameter(Mandatory)][string]$ContainerName,
    [string]$JobName,
    [string]$Namespace = "igt-floornet",
    [string]$OutputDir = ".",
    [string]$DashboardUID,
    [switch]$IncludeAuthMetric,
    [string]$AuthMetric,
    [string]$AuthPrimaryScheme,
    [string]$AuthSecondaryScheme,
    [switch]$IncludeClientMetric,
    [string]$ClientMetric,
    [bool]$IncludeApiDetail = $true,
    [switch]$IncludePMDAL,
    [string]$PMDALPrefix,
    [switch]$IncludeRabbitMQ,
    [string]$RabbitMQContainer,
    [string]$RabbitMQLabel = "job",
    [switch]$IncludeRedis,
    [string]$RedisInstance,
    [string]$RedisLabel = "job",
    [string[]]$Tags = @("kubernetes", "auto-generated"),
    [bool]$Minify = $true
)

$ErrorActionPreference = "Stop"

if (-not $JobName) { $JobName = $ContainerName }
if (-not $DashboardUID) { $DashboardUID = ($ContainerName -replace '[^a-z0-9]', '-') + "-ops" }
$safeFileName = ($ServiceName -replace '[^a-zA-Z0-9 ]', '') -replace '\s+', ' '

Write-Host "Generating dashboard: $ServiceName" -ForegroundColor Cyan
Write-Host "  Container: $ContainerName | Job: $JobName | Namespace: $Namespace"

# --- Panel ID counter ---
$script:panelId = 1
function NextId { $script:panelId++; return $script:panelId }

# --- Helper: Create a stat panel ---
function New-StatPanel($title, $expr, $unit = "short", $gridX = 0, $gridY = 0, $gridW = 4, $gridH = 4, $thresholds = $null) {
    $t = if ($thresholds) { $thresholds } else { @(@{color="green";value=$null},@{color="red";value=80}) }
    @{
        id = NextId; type = "stat"; title = $title
        datasource = $null
        targets = @(@{ expr = $expr; legendFormat = ""; refId = "A" })
        fieldConfig = @{ defaults = @{ unit = $unit; thresholds = @{ mode = "absolute"; steps = $t } } }
        gridPos = @{ h = $gridH; w = $gridW; x = $gridX; y = $gridY }
    }
}

# --- Helper: Create a timeseries panel ---
function New-TimeseriesPanel($title, $targets, $unit = "short", $gridX = 0, $gridY = 0, $gridW = 12, $gridH = 8) {
    $tList = @()
    foreach ($t in $targets) {
        $tList += @{ expr = $t.expr; legendFormat = $t.legend; refId = $t.refId }
    }
    @{
        id = NextId; type = "timeseries"; title = $title
        datasource = $null
        targets = $tList
        fieldConfig = @{ defaults = @{ unit = $unit; custom = @{ drawStyle = "line"; lineWidth = 2; fillOpacity = 10 } } }
        gridPos = @{ h = $gridH; w = $gridW; x = $gridX; y = $gridY }
    }
}

# --- Helper: Create a table panel ---
function New-TablePanel($title, $expr, $gridX = 0, $gridY = 0, $gridW = 24, $gridH = 8) {
    @{
        id = NextId; type = "table"; title = $title
        datasource = $null
        targets = @(@{ expr = $expr; legendFormat = ""; refId = "A"; instant = $true; format = "table" })
        gridPos = @{ h = $gridH; w = $gridW; x = $gridX; y = $gridY }
        transformations = @(@{ id = "organize"; options = @{ excludeByName = @{}; indexByName = @{}; renameByName = @{} } })
    }
}

# --- Helper: Create a row ---
function New-Row($title, $gridY = 0, $collapsed = $false, $panels = @()) {
    @{ id = NextId; type = "row"; title = $title; collapsed = $collapsed; panels = $panels; gridPos = @{ h = 1; w = 24; x = 0; y = $gridY } }
}

# --- Build panels ---
$panels = @()
$y = 0

# ============================================
# ROW 1: Overview Stats
# ============================================
$panels += New-Row "Overview — $ServiceName" $y
$y++

$panels += New-StatPanel "Status" "up{container=`"$ContainerName`"}" "short" 0 $y 3 4 @(@{color="red";value=$null},@{color="green";value=1})
$panels += New-StatPanel "Request Rate (req/min)" "sum(rate(http_requests_received_total{container=`"$ContainerName`"}[5m])) * 60" "reqps" 3 $y 5 4
$panels += New-StatPanel "Success Rate %" "100 * sum(rate(http_requests_received_total{container=`"$ContainerName`",code=~`"2..`"}[5m])) / sum(rate(http_requests_received_total{container=`"$ContainerName`"}[5m]))" "percent" 8 $y 4 4 @(@{color="red";value=$null},@{color="yellow";value=95},@{color="green";value=99})
$panels += New-StatPanel "P95 Latency" "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{container=`"$ContainerName`"}[5m])))" "s" 12 $y 4 4 @(@{color="green";value=$null},@{color="yellow";value=0.5},@{color="red";value=1})
$panels += New-StatPanel "5xx Errors (5m)" "sum(rate(http_requests_received_total{container=`"$ContainerName`",code=~`"5..`"}[5m])) * 300" "short" 16 $y 4 4 @(@{color="green";value=$null},@{color="red";value=1})
$panels += New-StatPanel "Active Requests" "sum(microsoft_aspnetcore_hosting_http_server_active_requests{container=`"$ContainerName`"})" "short" 20 $y 4 4
$y += 4

# ============================================
# ROW 2: Request Rate & Latency Over Time
# ============================================
$panels += New-Row "Request Rate & Latency" $y
$y++

$panels += New-TimeseriesPanel "Request Rate by Status Code (req/min)" @(
    @{ expr = "sum by (code) (rate(http_requests_received_total{container=`"$ContainerName`"}[5m])) * 60"; legend = "{{code}}"; refId = "A" }
) "reqps" 0 $y 12 8
$panels += New-TimeseriesPanel "Response Latency P50 / P95 / P99" @(
    @{ expr = "histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{container=`"$ContainerName`"}[5m])))"; legend = "P50"; refId = "A" },
    @{ expr = "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{container=`"$ContainerName`"}[5m])))"; legend = "P95"; refId = "B" },
    @{ expr = "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{container=`"$ContainerName`"}[5m])))"; legend = "P99"; refId = "C" }
) "s" 12 $y 12 8
$y += 8

# ============================================
# ROW 3: API Endpoint Details (skipped for services with no API actions)
# ============================================
if ($IncludeApiDetail) {
$panels += New-Row "API Endpoint Details" $y
$y++

$panels += New-TimeseriesPanel "Request Rate by Endpoint (req/min)" @(
    @{ expr = "sum by (action, method) (rate(http_requests_received_total{container=`"$ContainerName`", action!=`"`"}[5m])) * 60"; legend = "{{method}} {{action}}"; refId = "A" }
) "reqps" 0 $y 12 8
$panels += New-TimeseriesPanel "P95 Latency by Endpoint" @(
    @{ expr = "histogram_quantile(0.95, sum by (action, le) (rate(http_request_duration_seconds_bucket{container=`"$ContainerName`", action!=`"`"}[5m])))"; legend = "{{action}}"; refId = "A" }
) "s" 12 $y 12 8
$y += 8

$panels += New-TablePanel "Top Endpoints — Request Count & Avg Duration" "topk(25, sum by (action, method, code) (http_requests_received_total{container=`"$ContainerName`", action!=`"`"}))" 0 $y
$y += 8

$panels += New-TimeseriesPanel "Error Rate by Endpoint (4xx + 5xx)" @(
    @{ expr = "sum by (action, code) (rate(http_requests_received_total{container=`"$ContainerName`", action!=`"`", code=~`"[45]..`"}[5m])) * 60"; legend = "{{action}} {{code}}"; refId = "A" }
) "reqps" 0 $y 24 8
$y += 8
}

# ============================================
# ROW 4: Auth Scheme (optional)
# ============================================
if ($IncludeAuthMetric -and $AuthMetric) {
    $panels += New-Row "Authentication" $y
    $y++

    $panels += New-TimeseriesPanel "Auth Requests by Scheme (req/min)" @(
        @{ expr = "sum by (scheme) (rate($AuthMetric{container=`"$ContainerName`"}[5m])) * 60"; legend = "{{scheme}}"; refId = "A" }
    ) "reqps" 0 $y 12 8
    $panels += New-TimeseriesPanel "Auth Requests Total (req/min)" @(
        @{ expr = "sum(rate($AuthMetric{container=`"$ContainerName`"}[5m])) * 60"; legend = "total"; refId = "A" }
    ) "reqps" 12 $y 12 8
    $y += 8

    if ($AuthPrimaryScheme -and $AuthSecondaryScheme) {
        $panels += New-StatPanel "$AuthPrimaryScheme Requests (24h)" "sum(increase($AuthMetric{container=`"$ContainerName`",scheme=`"$AuthPrimaryScheme`"}[24h]))" "short" 0 $y 6 4
        $panels += New-StatPanel "$AuthSecondaryScheme Requests (24h)" "sum(increase($AuthMetric{container=`"$ContainerName`",scheme=`"$AuthSecondaryScheme`"}[24h]))" "short" 6 $y 6 4
        $panels += New-StatPanel "$AuthPrimaryScheme vs $AuthSecondaryScheme Ratio" "sum($AuthMetric{container=`"$ContainerName`",scheme=`"$AuthPrimaryScheme`"}) / sum($AuthMetric{container=`"$ContainerName`",scheme=`"$AuthSecondaryScheme`"})" "short" 12 $y 6 4
    }
    else {
        $panels += New-StatPanel "Auth Requests (24h)" "sum(increase($AuthMetric{container=`"$ContainerName`"}[24h]))" "short" 0 $y 18 4
    }
    $panels += New-StatPanel "401 Auth Errors (5m)" "sum(rate(http_requests_received_total{container=`"$ContainerName`",code=`"401`"}[5m])) * 300" "short" 18 $y 6 4 @(@{color="green";value=$null},@{color="red";value=1})
    $y += 4
}

# ============================================
# ROW: Client usage (optional)
# ============================================
if ($IncludeClientMetric -and $ClientMetric) {
    $panels += New-Row "Client Usage" $y
    $y++

    $panels += New-TimeseriesPanel "API Hits by Client Site (req/min)" @(
        @{ expr = "sum by (site) (rate($ClientMetric{container=`"$ContainerName`"}[5m])) * 60"; legend = "{{site}}"; refId = "A" }
    ) "reqps" 0 $y 12 8
    $panels += New-TimeseriesPanel "API Hits by Method" @(
        @{ expr = "sum by (method) (rate($ClientMetric{container=`"$ContainerName`"}[5m])) * 60"; legend = "{{method}}"; refId = "A" }
    ) "reqps" 12 $y 12 8
    $y += 8

    $panels += New-StatPanel "Active Client Sites" "count(count by (site) ($ClientMetric{container=`"$ContainerName`"}))" "short" 0 $y 6 4
    $panels += New-StatPanel "Client Hits (24h)" "sum(increase($ClientMetric{container=`"$ContainerName`"}[24h]))" "short" 6 $y 6 4
    $panels += New-StatPanel "Busiest Site (24h)" "max(sum by (site) (increase($ClientMetric{container=`"$ContainerName`"}[24h])))" "short" 12 $y 6 4
    $panels += New-StatPanel "Endpoints In Use" "count(count by (endpoint) ($ClientMetric{container=`"$ContainerName`"}))" "short" 18 $y 6 4
    $y += 4

    $panels += New-TablePanel "Top Client Site / Endpoint Usage" "topk(25, sum by (site, endpoint, method) ($ClientMetric{container=`"$ContainerName`"}))" 0 $y
    $y += 8
}

# ============================================
# ROW 5: PMDAL Database (optional)
# ============================================
if ($IncludePMDAL -and $PMDALPrefix) {
    $panels += New-Row "PMDAL (Database) Query Performance" $y
    $y++

    $panels += New-TimeseriesPanel "PMDAL Query Duration P50 / P95 / P99" @(
        @{ expr = "histogram_quantile(0.5, sum by (le) (rate(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_bucket[5m])))"; legend = "P50"; refId = "A" },
        @{ expr = "histogram_quantile(0.95, sum by (le) (rate(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_bucket[5m])))"; legend = "P95"; refId = "B" },
        @{ expr = "histogram_quantile(0.99, sum by (le) (rate(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_bucket[5m])))"; legend = "P99"; refId = "C" }
    ) "s" 0 $y 12 8
    $panels += New-TimeseriesPanel "PMDAL Query Rate (ops/s)" @(
        @{ expr = "rate(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_count[5m])"; legend = "{{Type}}"; refId = "A" }
    ) "ops" 12 $y 12 8
    $y += 8

    $panels += New-StatPanel "PMDAL Avg Query Time" "${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_sum / ${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_count" "s" 0 $y 8 4
    $panels += New-StatPanel "PMDAL Total Queries (24h)" "increase(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_count[24h])" "short" 8 $y 8 4
    $panels += New-TimeseriesPanel "PMDAL Query Duration Distribution" @(
        @{ expr = "rate(${PMDALPrefix}_HISTOGRAM_PMDAL_Processing_Time_bucket[5m])"; legend = "{{le}}"; refId = "A" }
    ) "short" 16 $y 8 4
    $y += 8
}

# ============================================
# ROW 6: Resource Usage
# ============================================
$panels += New-Row "Resource Usage (CPU / Memory / .NET Runtime)" $y
$y++

$panels += New-TimeseriesPanel "CPU Usage" @(
    @{ expr = "rate(process_cpu_seconds_total{container=`"$ContainerName`"}[5m])"; legend = "{{pod}}"; refId = "A" }
) "percentunit" 0 $y 8 8
$panels += New-TimeseriesPanel "Memory Working Set" @(
    @{ expr = "process_working_set_bytes{container=`"$ContainerName`"}"; legend = "{{pod}}"; refId = "A" }
) "bytes" 8 $y 8 8
$panels += New-TimeseriesPanel "Open Handles" @(
    @{ expr = "process_open_handles{container=`"$ContainerName`"}"; legend = "{{pod}}"; refId = "A" }
) "short" 16 $y 8 8
$y += 8

$panels += New-TimeseriesPanel ".NET Exceptions (per min)" @(
    @{ expr = "sum(rate(system_runtime_dotnet_exceptions{container=`"$ContainerName`"}[5m])) * 60"; legend = "exceptions"; refId = "A" }
) "short" 0 $y 8 8
$panels += New-TimeseriesPanel "GC Collections (per min)" @(
    @{ expr = "sum by (generation) (rate(system_runtime_dotnet_gc_collections{container=`"$ContainerName`"}[5m])) * 60"; legend = "Gen {{generation}}"; refId = "A" }
) "short" 8 $y 8 8
$panels += New-TimeseriesPanel "Thread Pool Threads" @(
    @{ expr = "system_runtime_dotnet_thread_pool_thread_count{container=`"$ContainerName`"}"; legend = "{{pod}}"; refId = "A" }
) "short" 16 $y 8 8
$y += 8

# ============================================
# ROW 7: Health & Uptime
# ============================================
$panels += New-Row "Health & Availability" $y
$y++

$panels += New-TimeseriesPanel "Service Uptime" @(
    @{ expr = "avg(process_uptime_seconds{container=`"$ContainerName`"})"; legend = "uptime"; refId = "A" }
) "s" 0 $y 8 6
$panels += New-TimeseriesPanel "Pod Readiness" @(
    @{ expr = "up{container=`"$ContainerName`"}"; legend = "{{pod}}"; refId = "A" }
) "short" 8 $y 8 6
$panels += New-TimeseriesPanel "ASP.NET Server Request Duration P95" @(
    @{ expr = "histogram_quantile(0.95, sum by (le) (rate(microsoft_aspnetcore_hosting_http_server_request_duration_bucket{container=`"$ContainerName`"}[5m])))"; legend = "P95"; refId = "A" }
) "s" 16 $y 8 6
$y += 6

# ============================================
# ROW 8: RabbitMQ (optional)
# ============================================
if ($IncludeRabbitMQ -and $RabbitMQContainer) {
    $panels += New-Row "RabbitMQ — Message Bus Health" $y
    $y++

    $rmq = "$RabbitMQLabel=`"$RabbitMQContainer`""

    $panels += New-StatPanel "Queue Depth" "sum(rabbitmq_queue_messages_ready{$rmq})" "short" 0 $y 6 4
    $panels += New-StatPanel "Unacked Messages" "sum(rabbitmq_queue_messages_unacked{$rmq})" "short" 6 $y 6 4 @(@{color="green";value=$null},@{color="red";value=100})
    $panels += New-StatPanel "Consumers" "sum(rabbitmq_queue_consumers{$rmq})" "short" 12 $y 6 4
    $panels += New-StatPanel "Channels" "sum(rabbitmq_channels{$rmq})" "short" 18 $y 6 4
    $y += 4

    $panels += New-TimeseriesPanel "Publish & Deliver Rate (msg/s)" @(
        @{ expr = "sum(rate(rabbitmq_queue_messages_published_total{$rmq}[5m]))"; legend = "Published"; refId = "A" },
        @{ expr = "sum(rate(rabbitmq_queue_messages_delivered_total{$rmq}[5m]))"; legend = "Delivered"; refId = "B" },
        @{ expr = "sum(rate(rabbitmq_queue_messages_acked_total{$rmq}[5m]))"; legend = "Acked"; refId = "C" }
    ) "ops" 0 $y 24 8
    $y += 8
}

# ============================================
# ROW 9: Redis (optional)
# ============================================
if ($IncludeRedis) {
    $panels += New-Row "Redis Cache Performance" $y
    $y++

    $redis = if ($RedisInstance) { "{$RedisLabel=`"$RedisInstance`"}" } else { "" }

    $panels += New-StatPanel "Redis Memory" "sum(redis_memory_used_bytes$redis)" "bytes" 0 $y 6 4
    $panels += New-StatPanel "Connected Clients" "sum(redis_connected_clients$redis)" "short" 6 $y 6 4
    $panels += New-StatPanel "Cache Hit Rate %" "100 * sum(redis_keyspace_hits_total$redis) / (sum(redis_keyspace_hits_total$redis) + sum(redis_keyspace_misses_total$redis))" "percent" 12 $y 6 4 @(@{color="red";value=$null},@{color="yellow";value=80},@{color="green";value=95})
    $panels += New-StatPanel "Ops/s" "sum(rate(redis_commands_processed_total$redis[5m]))" "ops" 18 $y 6 4
    $y += 4
}

# --- Build dashboard JSON ---
$dashboard = @{
    id = $null
    uid = $DashboardUID
    title = "$ServiceName Dashboard"
    tags = $Tags
    timezone = "browser"
    schemaVersion = 39
    version = 1
    refresh = "30s"
    time = @{ from = "now-6h"; to = "now" }
    editable = $true
    panels = $panels
    templating = @{
        list = @(
            @{
                name = "namespace"; type = "constant"; hide = 2
                query = $Namespace; current = @{ text = $Namespace; value = $Namespace }
            }
        )
    }
    annotations = @{ list = @() }
}

# --- Output ---
$jsonOutput = $dashboard | ConvertTo-Json -Depth 100
if ($Minify) {
    $jsonOutput = ($dashboard | ConvertTo-Json -Depth 100 -Compress)
}

$outputFile = Join-Path $OutputDir "$safeFileName Dashboard.json"
[System.IO.File]::WriteAllText($outputFile, $jsonOutput)

$sizeKB = [Math]::Round((Get-Item $outputFile).Length / 1024, 1)
$panelCount = 0
foreach ($p in $panels) { if ($p.type -eq "row") { $panelCount += $p.panels.Count } else { $panelCount++ } }

Write-Host "`nDashboard generated:" -ForegroundColor Green
Write-Host "  File: $outputFile"
Write-Host "  Size: $sizeKB KB"
Write-Host "  Panels: $panelCount"
Write-Host "  UID: $DashboardUID"
Write-Host "  Features: Auth=$IncludeAuthMetric PMDAL=$IncludePMDAL RabbitMQ=$IncludeRabbitMQ Redis=$IncludeRedis"

return $outputFile
