<#
Monitora la qualita' della connessione Internet con campionamento continuo.
Compatibile con Windows PowerShell 5.1 e PowerShell 7+ su Windows 10/11.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ----------------------------- Configurazione -----------------------------
$Config = [ordered]@{
    SampleIntervalSeconds = 1
    LatencyThresholdMs    = 250
    BaselineSeconds       = 60
    PingTimeoutMs         = 2000
    LogDirectory          = Join-Path $PSScriptRoot 'logs'
    ExtraTargets          = @()

    # Spike: latenza almeno SpikeMultiplier volte la baseline e almeno
    # SpikeMinimumIncreaseMs sopra la baseline.
    SpikeMultiplier       = 3.0
    SpikeMinimumIncreaseMs = 150
    MinimumBaselineSamples = 10

    # Filtri anti-rumore: un evento viene annunciato solo se e' forte,
    # coinvolge piu' target nello stesso campione, riguarda il gateway,
    # oppure persiste per piu' campioni consecutivi.
    SevereLatencyThresholdMs = 500
    EventStartMinTargets = 2
    EventStartConsecutiveSamples = 2

    # Se CPU o traffico generato dal PC sono alti durante un evento,
    # il riepilogo lo marca come possibile carico/saturazione locale.
    LocalCpuHighPercent = 85
    LocalDownloadHighMbps = 50
    LocalUploadHighMbps = 20

    # Un evento viene chiuso dopo N campioni puliti consecutivi.
    EventQuietSamples     = 2
    RecentEventsShown     = 10
}

$script:StopRequested = $false

function ConvertTo-CsvField {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $Text = [string]$Value
    if ($Text -match '[",\r\n]') {
        return '"' + $Text.Replace('"', '""') + '"'
    }
    return $Text
}

function Add-CsvLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)][hashtable]$Row
    )

    $Values = foreach ($Header in $Headers) {
        ConvertTo-CsvField $Row[$Header]
    }
    Add-Content -LiteralPath $Path -Value ($Values -join ',') -Encoding UTF8
}

function Initialize-CsvFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $HeaderLine = ($Headers | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
        Set-Content -LiteralPath $Path -Value $HeaderLine -Encoding UTF8
    }
}

function Get-DefaultGateway {
    try {
        $Route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1

        if ($Route) { return [string]$Route.NextHop }
    }
    catch {
        # Fallback per ambienti dove Get-NetRoute non e' disponibile o fallisce.
    }

    try {
        $Config = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' |
            Where-Object { $_.DefaultIPGateway -and $_.DefaultIPGateway.Count -gt 0 } |
            Select-Object -First 1

        if ($Config) { return [string]$Config.DefaultIPGateway[0] }
    }
    catch {
        return $null
    }

    return $null
}

function New-BaselineTracker {
    return [pscustomobject]@{
        Samples = New-Object System.Collections.Queue
        Sum     = 0.0
    }
}

function Get-Baseline {
    param(
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][int]$MinimumSamples
    )

    if ($Tracker.Samples.Count -lt $MinimumSamples) { return $null }
    return [math]::Round(($Tracker.Sum / $Tracker.Samples.Count), 2)
}

function Add-BaselineSample {
    param(
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][double]$LatencyMs,
        [Parameter(Mandatory)][int]$MaxSamples
    )

    $Tracker.Samples.Enqueue($LatencyMs)
    $Tracker.Sum += $LatencyMs

    while ($Tracker.Samples.Count -gt $MaxSamples) {
        $Removed = [double]$Tracker.Samples.Dequeue()
        $Tracker.Sum -= $Removed
    }
}

function Get-LocalLoadSnapshot {
    $CpuPercent = $null
    $DownloadMbps = $null
    $UploadMbps = $null
    $IsHigh = $false

    try {
        $Cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        if ($Cpu) {
            $CpuPercent = [math]::Round([double]$Cpu.PercentProcessorTime, 1)
        }
    }
    catch {
        $CpuPercent = $null
    }

    try {
        $Interfaces = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
            Where-Object {
                $_.Name -notmatch 'Loopback|isatap|Teredo|Bluetooth|Virtual|Hyper-V|VMware|VirtualBox'
            })

        if ($Interfaces.Count -gt 0) {
            $ReceivedBytes = ($Interfaces | Measure-Object -Property BytesReceivedPersec -Sum).Sum
            $SentBytes = ($Interfaces | Measure-Object -Property BytesSentPersec -Sum).Sum
            $DownloadMbps = [math]::Round(([double]$ReceivedBytes * 8 / 1000000), 2)
            $UploadMbps = [math]::Round(([double]$SentBytes * 8 / 1000000), 2)
        }
    }
    catch {
        $DownloadMbps = $null
        $UploadMbps = $null
    }

    return [pscustomobject]@{
        CpuPercent   = $CpuPercent
        DownloadMbps = $DownloadMbps
        UploadMbps   = $UploadMbps
        IsHigh       = $IsHigh
    }
}

function Update-LocalLoadFlag {
    param(
        [Parameter(Mandatory)]$Load,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $Load.IsHigh = (
        ($null -ne $Load.CpuPercent -and [double]$Load.CpuPercent -ge [double]$Config.LocalCpuHighPercent) -or
        ($null -ne $Load.DownloadMbps -and [double]$Load.DownloadMbps -ge [double]$Config.LocalDownloadHighMbps) -or
        ($null -ne $Load.UploadMbps -and [double]$Load.UploadMbps -ge [double]$Config.LocalUploadHighMbps)
    )

    return $Load
}

function Invoke-PingBatch {
    param(
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $PingJobs = foreach ($Target in $Targets) {
        $Ping = New-Object System.Net.NetworkInformation.Ping
        [pscustomobject]@{
            Target = $Target
            Ping   = $Ping
            Task   = $Ping.SendPingAsync($Target, $TimeoutMs)
        }
    }

    $Tasks = $PingJobs | ForEach-Object { $_.Task }
    [void][System.Threading.Tasks.Task]::WaitAll($Tasks, ($TimeoutMs + 200))

    foreach ($Job in $PingJobs) {
        $Status = 'ERROR'
        $Latency = $null
        $ErrorText = $null

        try {
            if (-not $Job.Task.IsCompleted) {
                $Status = 'TIMEOUT'
                $ErrorText = 'Ping task did not complete before local wait timeout'
            }
            elseif ($Job.Task.IsFaulted) {
                $Status = 'ERROR'
                $ErrorText = $Job.Task.Exception.GetBaseException().Message
            }
            else {
                $Reply = $Job.Task.Result
                if ($Reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $Status = 'OK'
                    $Latency = [int64]$Reply.RoundtripTime
                }
                elseif ($Reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TimedOut) {
                    $Status = 'TIMEOUT'
                }
                else {
                    $Status = 'ERROR'
                    $ErrorText = [string]$Reply.Status
                }
            }
        }
        catch {
            $Status = 'ERROR'
            $ErrorText = $_.Exception.Message
        }
        finally {
            $Job.Ping.Dispose()
        }

        [pscustomobject]@{
            Target    = $Job.Target
            LatencyMs = $Latency
            Status    = $Status
            Error     = $ErrorText
        }
    }
}

function New-EventState {
    param(
        [Parameter(Mandatory)][int]$EventNumber,
        [Parameter(Mandatory)][datetime]$StartTime
    )

    return [pscustomobject]@{
        EventId         = ('EVT-{0:yyyyMMdd-HHmmss}-{1:0000}' -f $StartTime, $EventNumber)
        StartTime       = $StartTime
        EndTime         = $StartTime
        TargetsAffected = New-Object 'System.Collections.Generic.HashSet[string]'
        MaxLatencyMs    = $null
        TimeoutCount    = 0
        SpikeCount      = 0
        GatewayProblem  = $false
        ExternalProblem = $false
        LocalLoad       = $false
        MaxCpuPercent   = $null
        MaxDownloadMbps = $null
        MaxUploadMbps   = $null
        QuietSamples    = 0
    }
}

function Update-EventState {
    param(
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)][datetime]$Timestamp,
        [Parameter(Mandatory)][object[]]$ProblemRows,
        [Parameter(Mandatory)][string]$GatewayTarget,
        [Parameter(Mandatory)]$LocalLoad
    )

    foreach ($Row in $ProblemRows) {
        [void]$Event.TargetsAffected.Add([string]$Row.Target)
        if ($null -ne $Row.LatencyMs) {
            if ($null -eq $Event.MaxLatencyMs -or [int64]$Row.LatencyMs -gt [int64]$Event.MaxLatencyMs) {
                $Event.MaxLatencyMs = [int64]$Row.LatencyMs
            }
        }
        if ($Row.Status -eq 'TIMEOUT') { $Event.TimeoutCount++ }
        if ($Row.Spike) { $Event.SpikeCount++ }
        if ($Row.Target -eq $GatewayTarget) { $Event.GatewayProblem = $true }
        else { $Event.ExternalProblem = $true }
    }

    if ($LocalLoad.IsHigh) { $Event.LocalLoad = $true }
    if ($null -ne $LocalLoad.CpuPercent) {
        if ($null -eq $Event.MaxCpuPercent -or [double]$LocalLoad.CpuPercent -gt [double]$Event.MaxCpuPercent) {
            $Event.MaxCpuPercent = [double]$LocalLoad.CpuPercent
        }
    }
    if ($null -ne $LocalLoad.DownloadMbps) {
        if ($null -eq $Event.MaxDownloadMbps -or [double]$LocalLoad.DownloadMbps -gt [double]$Event.MaxDownloadMbps) {
            $Event.MaxDownloadMbps = [double]$LocalLoad.DownloadMbps
        }
    }
    if ($null -ne $LocalLoad.UploadMbps) {
        if ($null -eq $Event.MaxUploadMbps -or [double]$LocalLoad.UploadMbps -gt [double]$Event.MaxUploadMbps) {
            $Event.MaxUploadMbps = [double]$LocalLoad.UploadMbps
        }
    }

    $Event.EndTime = $Timestamp
}

function Test-ShouldStartEvent {
    param(
        [Parameter(Mandatory)][object[]]$ProblemRows,
        [Parameter(Mandatory)][hashtable]$ProblemStreakByTarget,
        [AllowNull()][string]$GatewayTarget,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    if ($ProblemRows.Count -eq 0) { return $false }

    $AffectedTargets = @($ProblemRows | Select-Object -ExpandProperty Target -Unique)
    if ($AffectedTargets.Count -ge [int]$Config.EventStartMinTargets) {
        return $true
    }

    foreach ($Row in $ProblemRows) {
        if ($GatewayTarget -and $Row.Target -eq $GatewayTarget) {
            return $true
        }

        if ($null -ne $Row.LatencyMs -and [int64]$Row.LatencyMs -ge [int64]$Config.SevereLatencyThresholdMs) {
            return $true
        }

        if ($ProblemStreakByTarget.ContainsKey($Row.Target) -and
            [int]$ProblemStreakByTarget[$Row.Target] -ge [int]$Config.EventStartConsecutiveSamples) {
            return $true
        }
    }

    return $false
}

function Get-EventClassification {
    param([Parameter(Mandatory)]$Event)

    if ($Event.LocalLoad -and $Event.GatewayProblem) { return 'LAN/WiFi + LocalLoad/Saturation' }
    if ($Event.LocalLoad -and $Event.ExternalProblem) { return 'Internet/ISP + LocalLoad/Saturation' }
    if ($Event.LocalLoad) { return 'LocalLoad/Saturation' }
    if ($Event.GatewayProblem) { return 'LAN/WiFi' }
    if ($Event.ExternalProblem) { return 'Internet/ISP' }
    return 'Unknown'
}

function Get-ProvisionalClassification {
    param(
        [Parameter(Mandatory)][object[]]$ProblemRows,
        [AllowNull()][string]$GatewayTarget,
        [Parameter(Mandatory)]$LocalLoad
    )

    $GatewayProblem = $false
    $ExternalProblem = $false

    foreach ($Row in $ProblemRows) {
        if ($GatewayTarget -and $Row.Target -eq $GatewayTarget) {
            $GatewayProblem = $true
        }
        else {
            $ExternalProblem = $true
        }
    }

    if ($LocalLoad.IsHigh -and $GatewayProblem) { return 'LAN/WiFi + LocalLoad/Saturation' }
    if ($LocalLoad.IsHigh -and $ExternalProblem) { return 'Internet/ISP + LocalLoad/Saturation' }
    if ($LocalLoad.IsHigh) { return 'LocalLoad/Saturation' }
    if ($GatewayProblem) { return 'LAN/WiFi' }
    if ($ExternalProblem) { return 'Internet/ISP' }
    return 'Unknown'
}

function Get-ClassificationColor {
    param([AllowNull()][string]$Classification)

    switch -Wildcard ($Classification) {
        '*LocalLoad*' { return 'Cyan' }
        'LAN/WiFi*' { return 'Red' }
        'Internet/ISP*' { return 'Yellow' }
        default { return 'DarkGray' }
    }
}

function Write-EventSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)]$Event
    )

    $Duration = [math]::Round(($Event.EndTime - $Event.StartTime).TotalSeconds, 2)
    $Targets = ($Event.TargetsAffected | Sort-Object) -join ';'

    Add-CsvLine -Path $Path -Headers $Headers -Row @{
        EventId         = $Event.EventId
        StartTime       = $Event.StartTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
        EndTime         = $Event.EndTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
        DurationSeconds = $Duration
        TargetsAffected = $Targets
        MaxLatencyMs    = $Event.MaxLatencyMs
        TimeoutCount    = $Event.TimeoutCount
        SpikeCount      = $Event.SpikeCount
        LocalLoad       = $Event.LocalLoad
        MaxCpuPercent   = $Event.MaxCpuPercent
        MaxDownloadMbps = $Event.MaxDownloadMbps
        MaxUploadMbps   = $Event.MaxUploadMbps
        Classification  = Get-EventClassification -Event $Event
    }
}

function ConvertTo-EventSnapshot {
    param([Parameter(Mandatory)]$Event)

    return [pscustomobject]@{
        EventId         = $Event.EventId
        StartTime       = $Event.StartTime
        EndTime         = $Event.EndTime
        DurationSeconds = [math]::Round(($Event.EndTime - $Event.StartTime).TotalSeconds, 2)
        TargetsAffected = ($Event.TargetsAffected | Sort-Object) -join ';'
        MaxLatencyMs    = $Event.MaxLatencyMs
        TimeoutCount    = $Event.TimeoutCount
        SpikeCount      = $Event.SpikeCount
        LocalLoad       = $Event.LocalLoad
        MaxCpuPercent   = $Event.MaxCpuPercent
        MaxDownloadMbps = $Event.MaxDownloadMbps
        MaxUploadMbps   = $Event.MaxUploadMbps
        Classification  = Get-EventClassification -Event $Event
    }
}

function Add-RecentEvent {
    param(
        [Parameter(Mandatory)][System.Collections.Queue]$RecentEvents,
        [Parameter(Mandatory)]$Event,
        [Parameter(Mandatory)][int]$Limit
    )

    $RecentEvents.Enqueue((ConvertTo-EventSnapshot -Event $Event))
    while ($RecentEvents.Count -gt $Limit) {
        [void]$RecentEvents.Dequeue()
    }
}

function Format-EventSnapshot {
    param([Parameter(Mandatory)]$Event)

    return ('{0} {1}-{2} durata={3}s target={4} max={5}ms timeout={6} spike={7} load={8} down={9}Mbps up={10}Mbps cpu={11}% classe={12}' -f
        $Event.EventId,
        $Event.StartTime.ToString('HH:mm:ss'),
        $Event.EndTime.ToString('HH:mm:ss'),
        $Event.DurationSeconds,
        $Event.TargetsAffected,
        $(if ($null -eq $Event.MaxLatencyMs) { '-' } else { $Event.MaxLatencyMs }),
        $Event.TimeoutCount,
        $Event.SpikeCount,
        $Event.LocalLoad,
        $(if ($null -eq $Event.MaxDownloadMbps) { '-' } else { $Event.MaxDownloadMbps }),
        $(if ($null -eq $Event.MaxUploadMbps) { '-' } else { $Event.MaxUploadMbps }),
        $(if ($null -eq $Event.MaxCpuPercent) { '-' } else { $Event.MaxCpuPercent }),
        $Event.Classification
    )
}

function Write-EventConsoleSummary {
    param(
        [Parameter(Mandatory)][int]$TotalEvents,
        [Parameter(Mandatory)][System.Collections.Queue]$RecentEvents
    )

    Write-Host ''
    if ($TotalEvents -eq 0) {
        Write-Host '[VARIAZIONI] Nessun evento rilevato finora.' -ForegroundColor DarkGray
        return
    }

    Write-Host "[VARIAZIONI] Totale eventi rilevati in questa sessione: $TotalEvents" -ForegroundColor White
    foreach ($Event in $RecentEvents) {
        Write-Host "  - $(Format-EventSnapshot -Event $Event)" -ForegroundColor (Get-ClassificationColor -Classification $Event.Classification)
    }
}

function Format-LiveStatus {
    param(
        [Parameter(Mandatory)][datetime]$Timestamp,
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)]$LocalLoad,
        [AllowNull()][string]$EventId,
        [AllowNull()][string]$Classification
    )

    $Parts = foreach ($Row in $Rows) {
        $LatencyText = if ($null -eq $Row.LatencyMs) { '-' } else { '{0}ms' -f $Row.LatencyMs }
        $SpikeText = if ($Row.Spike) { '/SPIKE' } else { '' }
        '{0}:{1}{2}{3}' -f $Row.Target, $LatencyText, $(if ($Row.Status -ne 'OK') { '/' + $Row.Status } else { '' }), $SpikeText
    }

    $EventText = if ($EventId) { " EVENT=$EventId [$Classification]" } else { '' }
    $LoadText = if ($LocalLoad.IsHigh) {
        ' | LOAD down={0}Mbps up={1}Mbps cpu={2}%' -f
            $(if ($null -eq $LocalLoad.DownloadMbps) { '-' } else { $LocalLoad.DownloadMbps }),
            $(if ($null -eq $LocalLoad.UploadMbps) { '-' } else { $LocalLoad.UploadMbps }),
            $(if ($null -eq $LocalLoad.CpuPercent) { '-' } else { $LocalLoad.CpuPercent })
    }
    else {
        ''
    }

    return ('{0} | {1}{2}{3}' -f $Timestamp.ToString('yyyy-MM-dd HH:mm:ss'), ($Parts -join ' | '), $EventText, $LoadText)
}

function Test-CtrlCPressed {
    try {
        while ([Console]::KeyAvailable) {
            $Key = [Console]::ReadKey($true)
            $IsCtrl = (($Key.Modifiers -band [ConsoleModifiers]::Control) -eq [ConsoleModifiers]::Control)
            if ($IsCtrl -and $Key.Key -eq [ConsoleKey]::C) {
                return $true
            }
        }
    }
    catch {
        return $false
    }

    return $false
}

function Wait-MonitorInterval {
    param([Parameter(Mandatory)][int]$Milliseconds)

    $Remaining = $Milliseconds
    while ($Remaining -gt 0 -and -not $script:StopRequested) {
        if (Test-CtrlCPressed) {
            $script:StopRequested = $true
            break
        }

        $Chunk = [math]::Min(100, $Remaining)
        Start-Sleep -Milliseconds $Chunk
        $Remaining -= $Chunk
    }
}

function Start-InternetMonitor {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $Gateway = Get-DefaultGateway
    if (-not $Gateway) {
        Write-Warning 'Gateway locale non rilevato automaticamente. Il target gateway verra'' saltato.'
    }

    $Targets = @()
    if ($Gateway) { $Targets += $Gateway }
    $Targets += @('1.1.1.1', '8.8.8.8')
    $Targets += @($Config.ExtraTargets)
    $Targets = $Targets | Where-Object { $_ } | Select-Object -Unique

    if ($Targets.Count -eq 0) {
        throw 'Nessun target da monitorare.'
    }

    New-Item -ItemType Directory -Path $Config.LogDirectory -Force | Out-Null

    $SessionStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $DetailLogPath = Join-Path $Config.LogDirectory "internet-quality-$SessionStamp.csv"
    $EventLogPath = Join-Path $Config.LogDirectory "internet-events-$SessionStamp.csv"

    $DetailHeaders = @('Timestamp', 'Target', 'LatencyMs', 'Status', 'BaselineMs', 'Spike', 'EventId', 'CpuPercent', 'DownloadMbps', 'UploadMbps', 'LocalLoad', 'Error')
    $EventHeaders = @('EventId', 'StartTime', 'EndTime', 'DurationSeconds', 'TargetsAffected', 'MaxLatencyMs', 'TimeoutCount', 'SpikeCount', 'LocalLoad', 'MaxCpuPercent', 'MaxDownloadMbps', 'MaxUploadMbps', 'Classification')

    Initialize-CsvFile -Path $DetailLogPath -Headers $DetailHeaders
    Initialize-CsvFile -Path $EventLogPath -Headers $EventHeaders

    $BaselineByTarget = @{}
    $BaselineSampleLimit = [math]::Max(1, [int][math]::Ceiling([double]$Config.BaselineSeconds / [double]$Config.SampleIntervalSeconds))
    foreach ($Target in $Targets) {
        $BaselineByTarget[$Target] = New-BaselineTracker
    }

    $ProblemStreakByTarget = @{}
    foreach ($Target in $Targets) {
        $ProblemStreakByTarget[$Target] = 0
    }

    $CurrentEvent = $null
    $EventCounter = 0
    $ClosedEventCount = 0
    $RecentEvents = New-Object System.Collections.Queue
    $OriginalTreatControlCAsInput = $null

    Write-Host "Target monitorati: $($Targets -join ', ')"
    Write-Host "Log dettagliato: $DetailLogPath"
    Write-Host "Riepilogo eventi: $EventLogPath"
    Write-Host 'Premi Ctrl+C per terminare e chiudere gli eventi aperti.'

    try {
        try {
            $OriginalTreatControlCAsInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
        }
        catch {
            $OriginalTreatControlCAsInput = $null
        }

        while (-not $script:StopRequested) {
            if (Test-CtrlCPressed) {
                $script:StopRequested = $true
                break
            }

            $LoopStart = Get-Date
            $TimestampText = $LoopStart.ToString('yyyy-MM-dd HH:mm:ss.fff')
            $LocalLoad = Update-LocalLoadFlag -Load (Get-LocalLoadSnapshot) -Config $Config
            $PingResults = @(Invoke-PingBatch -Targets $Targets -TimeoutMs $Config.PingTimeoutMs)
            $Rows = @()

            foreach ($Result in $PingResults) {
                $Tracker = $BaselineByTarget[$Result.Target]
                $Baseline = Get-Baseline -Tracker $Tracker -MinimumSamples $Config.MinimumBaselineSamples
                $Spike = $false

                if ($Result.Status -eq 'OK' -and $null -ne $Baseline -and $Baseline -gt 0) {
                    $Spike = (
                        [double]$Result.LatencyMs -ge ([double]$Baseline * [double]$Config.SpikeMultiplier) -and
                        ([double]$Result.LatencyMs - [double]$Baseline) -ge [double]$Config.SpikeMinimumIncreaseMs
                    )
                }

                $Row = [pscustomobject]@{
                    Timestamp  = $TimestampText
                    Target     = $Result.Target
                    LatencyMs  = $Result.LatencyMs
                    Status     = $Result.Status
                    BaselineMs = $Baseline
                    Spike      = $Spike
                    EventId    = ''
                    CpuPercent = $LocalLoad.CpuPercent
                    DownloadMbps = $LocalLoad.DownloadMbps
                    UploadMbps = $LocalLoad.UploadMbps
                    LocalLoad  = $LocalLoad.IsHigh
                    Error      = $Result.Error
                }

                if ($Result.Status -eq 'OK' -and $null -ne $Result.LatencyMs) {
                    Add-BaselineSample -Tracker $Tracker -LatencyMs ([double]$Result.LatencyMs) -MaxSamples $BaselineSampleLimit
                }

                $Rows += $Row
            }

            $ProblemRows = @($Rows | Where-Object {
                $_.Status -ne 'OK' -or
                ($null -ne $_.LatencyMs -and [int64]$_.LatencyMs -gt [int64]$Config.LatencyThresholdMs) -or
                $_.Spike
            })

            $ProblemTargetSet = @{}
            foreach ($ProblemRow in $ProblemRows) {
                $ProblemTargetSet[$ProblemRow.Target] = $true
            }

            foreach ($Target in $Targets) {
                if ($ProblemTargetSet.ContainsKey($Target)) {
                    $ProblemStreakByTarget[$Target] = [int]$ProblemStreakByTarget[$Target] + 1
                }
                else {
                    $ProblemStreakByTarget[$Target] = 0
                }
            }

            if ($ProblemRows.Count -gt 0) {
                $ShouldStartEvent = Test-ShouldStartEvent -ProblemRows $ProblemRows -ProblemStreakByTarget $ProblemStreakByTarget -GatewayTarget $Gateway -Config $Config
                $ProvisionalClassification = Get-ProvisionalClassification -ProblemRows $ProblemRows -GatewayTarget $Gateway -LocalLoad $LocalLoad

                if ($null -eq $CurrentEvent -and $ShouldStartEvent) {
                    $EventCounter++
                    $CurrentEvent = New-EventState -EventNumber $EventCounter -StartTime $LoopStart
                    Write-Host ''
                    Write-Host ('[VARIAZIONE] Inizio evento {0} alle {1}. Target iniziali: {2}' -f
                        $CurrentEvent.EventId,
                        $CurrentEvent.StartTime.ToString('yyyy-MM-dd HH:mm:ss'),
                        (($ProblemRows | Select-Object -ExpandProperty Target -Unique) -join ';')
                    ) -ForegroundColor (Get-ClassificationColor -Classification $ProvisionalClassification)
                }

                if ($null -ne $CurrentEvent) {
                    $CurrentEvent.QuietSamples = 0
                    Update-EventState -Event $CurrentEvent -Timestamp $LoopStart -ProblemRows $ProblemRows -GatewayTarget $Gateway -LocalLoad $LocalLoad

                    foreach ($Row in $ProblemRows) {
                        $Row.EventId = $CurrentEvent.EventId
                    }
                }
            }
            elseif ($null -ne $CurrentEvent) {
                $CurrentEvent.QuietSamples++
                if ($CurrentEvent.QuietSamples -ge [int]$Config.EventQuietSamples) {
                    $CurrentEvent.EndTime = $LoopStart
                    Write-EventSummary -Path $EventLogPath -Headers $EventHeaders -Event $CurrentEvent
                    $ClosedEventCount++
                    Add-RecentEvent -RecentEvents $RecentEvents -Event $CurrentEvent -Limit ([int]$Config.RecentEventsShown)
                    $ClosedSnapshot = ConvertTo-EventSnapshot -Event $CurrentEvent
                    Write-Host ''
                    Write-Host "[VARIAZIONE] Evento chiuso: $(Format-EventSnapshot -Event $ClosedSnapshot)" -ForegroundColor (Get-ClassificationColor -Classification $ClosedSnapshot.Classification)
                    Write-EventConsoleSummary -TotalEvents $ClosedEventCount -RecentEvents $RecentEvents
                    $CurrentEvent = $null
                }
            }

            foreach ($Row in $Rows) {
                Add-CsvLine -Path $DetailLogPath -Headers $DetailHeaders -Row @{
                    Timestamp  = $Row.Timestamp
                    Target     = $Row.Target
                    LatencyMs  = $Row.LatencyMs
                    Status     = $Row.Status
                    BaselineMs = $Row.BaselineMs
                    Spike      = $Row.Spike
                    EventId    = $Row.EventId
                    CpuPercent = $Row.CpuPercent
                    DownloadMbps = $Row.DownloadMbps
                    UploadMbps = $Row.UploadMbps
                    LocalLoad  = $Row.LocalLoad
                    Error      = $Row.Error
                }
            }

            $CurrentClassification = if ($CurrentEvent) { Get-EventClassification -Event $CurrentEvent } else { $null }
            $LiveLine = Format-LiveStatus -Timestamp $LoopStart -Rows $Rows -LocalLoad $LocalLoad -EventId $(if ($CurrentEvent) { $CurrentEvent.EventId } else { $null }) -Classification $CurrentClassification
            try { $ConsoleWidth = [Console]::WindowWidth } catch { $ConsoleWidth = 120 }
            if ($CurrentEvent) {
                Write-Host "`r$($LiveLine.PadRight($ConsoleWidth - 1))" -NoNewline -ForegroundColor (Get-ClassificationColor -Classification $CurrentClassification)
            }
            else {
                Write-Host "`r$($LiveLine.PadRight($ConsoleWidth - 1))" -NoNewline
            }

            $Elapsed = ((Get-Date) - $LoopStart).TotalMilliseconds
            $SleepMs = ([double]$Config.SampleIntervalSeconds * 1000) - $Elapsed
            if ($SleepMs -gt 0) {
                Wait-MonitorInterval -Milliseconds ([int]$SleepMs)
            }
        }
    }
    finally {
        if ($null -ne $OriginalTreatControlCAsInput) {
            try { [Console]::TreatControlCAsInput = $OriginalTreatControlCAsInput } catch { }
        }

        if ($null -ne $CurrentEvent) {
            Write-EventSummary -Path $EventLogPath -Headers $EventHeaders -Event $CurrentEvent
            $ClosedEventCount++
            Add-RecentEvent -RecentEvents $RecentEvents -Event $CurrentEvent -Limit ([int]$Config.RecentEventsShown)
        }

        Write-Host ''
        Write-EventConsoleSummary -TotalEvents $ClosedEventCount -RecentEvents $RecentEvents
        Write-Host 'Monitoraggio terminato.'
        Write-Host "Log dettagliato: $DetailLogPath"
        Write-Host "Riepilogo eventi: $EventLogPath"
    }
}

Start-InternetMonitor -Config $Config
