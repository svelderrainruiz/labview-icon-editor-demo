#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$BaseVi,
    [string]$HeadVi,
    [string]$OutputDir,
    [string]$LabVIEWExePath,
    [string]$LabVIEWBitness = '64',
    [string]$LVComparePath,
    [string[]]$Flags,
    [switch]$ReplaceFlags,
    [switch]$AllowSameLeaf,
    [switch]$RenderReport,
    [ValidateSet('html', 'xml', 'text')]
    [string[]]$ReportFormat = @('html'),
    [string]$JsonLogPath,
    [switch]$Quiet,
    [switch]$LeakCheck,
    [double]$LeakGraceSeconds = 0,
    [string]$LeakJsonPath,
    [string]$CaptureScriptPath,
    [switch]$Summary,
    [Nullable[int]]$TimeoutSeconds,
    [string]$NoiseProfile = 'full',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ("[hosted-linux-adapter] baseViNull={0} headViNull={1} outputDirNull={2} scriptsRootEnvSet={3}" -f `
    [string]::IsNullOrWhiteSpace($BaseVi), `
    [string]::IsNullOrWhiteSpace($HeadVi), `
    [string]::IsNullOrWhiteSpace($OutputDir), `
    (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_SCRIPTS_ROOT)))

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Resolve-OutputDirectory {
    param([AllowNull()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        $tempRoot = [System.IO.Path]::GetTempPath()
        return Join-Path $tempRoot ("comparevi-history-linux-" + [guid]::NewGuid().ToString('N'))
    }

    return Resolve-AbsolutePath -PathValue $PathValue -BasePath (Get-Location).Path
}

function Resolve-HostedCompareReportType {
    param(
        [string[]]$ReportFormatValue,
        [switch]$RenderReportValue
    )

    foreach ($candidate in @($ReportFormatValue)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim().ToLowerInvariant()
        }
    }

    $envValue = [System.Environment]::GetEnvironmentVariable('COMPAREVI_REPORT_FORMAT', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim().ToLowerInvariant()
    }

    if ($RenderReportValue.IsPresent) {
        return 'html'
    }

    return 'html'
}

function Resolve-HostedCompareFlags {
    param(
        [string[]]$FlagValues,
        [switch]$ReplaceFlagsValue
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    if (-not $ReplaceFlagsValue.IsPresent) {
        $envFlags = [System.Environment]::GetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($envFlags)) {
            foreach ($line in @($envFlags -split "(`r`n|`n|`r)")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $resolved.Add($line.Trim()) | Out-Null
                }
            }
        }
    }

    foreach ($flag in @($FlagValues)) {
        if (-not [string]::IsNullOrWhiteSpace($flag)) {
            $resolved.Add($flag.Trim()) | Out-Null
        }
    }

    return @($resolved | Select-Object -Unique)
}

function Resolve-HostedCompareScriptsRoot {
    $scriptsRoot = [System.Environment]::GetEnvironmentVariable('COMPAREVI_SCRIPTS_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($scriptsRoot)) {
        throw 'COMPAREVI_SCRIPTS_ROOT was not set by comparevi-history. This adapter must run through the facade.'
    }

    $resolved = [System.IO.Path]::GetFullPath($scriptsRoot)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "COMPAREVI_SCRIPTS_ROOT does not exist: $resolved"
    }

    return $resolved
}

function Resolve-HostedCompareRunner {
    param([Parameter(Mandatory = $true)][string]$ScriptsRoot)

    $runnerScript = Join-Path $ScriptsRoot 'tools' 'Run-NILinuxContainerCompare.ps1'
    if (-not (Test-Path -LiteralPath $runnerScript -PathType Leaf)) {
        throw "Run-NILinuxContainerCompare.ps1 not found at '$runnerScript'."
    }

    return $runnerScript
}

function Resolve-ReportExtension {
    param([Parameter(Mandatory = $true)][string]$ReportTypeValue)

    switch ($ReportTypeValue) {
        'xml' { return 'xml' }
        'text' { return 'txt' }
        default { return 'html' }
    }
}

function Copy-IfExists {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return $false
    }

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return $true
}

function Copy-OrWriteArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [AllowNull()][string]$FallbackContent = ''
    )

    if (Copy-IfExists -SourcePath $SourcePath -DestinationPath $DestinationPath) {
        return
    }

    if ($null -eq $FallbackContent) {
        $FallbackContent = ''
    }
    Set-Content -LiteralPath $DestinationPath -Value $FallbackContent -Encoding utf8
}

function Get-OptionalCaptureText {
    param(
        [AllowNull()][psobject]$SourceCapture,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($null -eq $SourceCapture) {
        return $null
    }
    if (-not $SourceCapture.PSObject.Properties[$PropertyName]) {
        return $null
    }

    $value = [string]$SourceCapture.$PropertyName
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Resolve-TranslatedDiffState {
    param([AllowNull()][psobject]$SourceCapture)

    if ($null -eq $SourceCapture) {
        return $false
    }
    if ($SourceCapture.PSObject.Properties['diff']) {
        return [bool]$SourceCapture.diff
    }
    if ($SourceCapture.PSObject.Properties['isDiff']) {
        return [bool]$SourceCapture.isDiff
    }
    if ($SourceCapture.PSObject.Properties['exitCode']) {
        return ([int]$SourceCapture.exitCode -eq 1)
    }

    return $false
}

function New-FallbackCapture {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$ReportPathValue,
        [AllowNull()][string]$Message
    )

    return [pscustomobject]@{
        schema = 'ni-linux-container-compare/v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        image = $Image
        reportPath = $ReportPathValue
        exitCode = $ExitCode
        status = if ($ExitCode -eq 1) { 'diff' } elseif ($ExitCode -eq 0) { 'ok' } else { 'error' }
        message = $Message
        isDiff = ($ExitCode -eq 1)
    }
}

function Convert-ToTranslatedCapture {
    param(
        [AllowNull()][psobject]$SourceCapture,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$BaseViPath,
        [Parameter(Mandatory = $true)][string]$HeadViPath,
        [Parameter(Mandatory = $true)][string]$ReportPathValue,
        [Parameter(Mandatory = $true)][string]$CapturePathValue,
        [Parameter(Mandatory = $true)][string]$StdOutPathValue,
        [Parameter(Mandatory = $true)][string]$StdErrPathValue,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ResolvedFlags,
        [Parameter(Mandatory = $true)][string]$ReportTypeValue,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds,
        [Parameter(Mandatory = $true)][string]$LabVIEWBitnessValue,
        [AllowNull()][string]$LabVIEWExePathValue
    )

    $reportSize = if (Test-Path -LiteralPath $ReportPathValue -PathType Leaf) {
        [int64](Get-Item -LiteralPath $ReportPathValue).Length
    } else {
        [int64]0
    }
    $stdoutLength = if (Test-Path -LiteralPath $StdOutPathValue -PathType Leaf) {
        (Get-Content -LiteralPath $StdOutPathValue -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    } else {
        0
    }
    $stderrLength = if (Test-Path -LiteralPath $StdErrPathValue -PathType Leaf) {
        (Get-Content -LiteralPath $StdErrPathValue -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    } else {
        0
    }

    $artifacts = [ordered]@{
        imageCount = 0
        images = @()
        reportSizeBytes = $reportSize
    }
    if (
        $null -ne $SourceCapture -and
        $SourceCapture.PSObject.Properties['reportAnalysis'] -and
        $SourceCapture.reportAnalysis -and
        $SourceCapture.reportAnalysis.PSObject.Properties['diffImageCount']
    ) {
        $artifacts['imageCount'] = [int]$SourceCapture.reportAnalysis.diffImageCount
    }
    if (
        $null -ne $SourceCapture -and
        $SourceCapture.PSObject.Properties['containerArtifacts'] -and
        $SourceCapture.containerArtifacts -and
        $SourceCapture.containerArtifacts.PSObject.Properties['exportDir'] -and
        $SourceCapture.containerArtifacts.exportDir
    ) {
        $artifacts['exportDir'] = [string]$SourceCapture.containerArtifacts.exportDir
    }

    $cliNode = [ordered]@{
        path = "docker:$Image"
        reportType = $ReportTypeValue
        reportPath = $ReportPathValue
        artifacts = $artifacts
    }
    $cliStatus = Get-OptionalCaptureText -SourceCapture $SourceCapture -PropertyName 'status'
    if ($cliStatus) {
        $cliNode['status'] = $cliStatus
    }
    $cliMessage = Get-OptionalCaptureText -SourceCapture $SourceCapture -PropertyName 'message'
    if ($cliMessage) {
        $cliNode['message'] = $cliMessage
    }

    return [ordered]@{
        schema = 'lvcompare-capture-v1'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        base = $BaseViPath
        head = $HeadViPath
        cliPath = "docker:$Image"
        args = @($ResolvedFlags)
        exitCode = if ($null -ne $SourceCapture -and $SourceCapture.PSObject.Properties['exitCode']) { [int]$SourceCapture.exitCode } else { $null }
        seconds = [math]::Round($ElapsedSeconds, 3)
        stdoutLen = $stdoutLength
        stderrLen = $stderrLength
        command = if ($null -ne $SourceCapture -and $SourceCapture.PSObject.Properties['command']) { [string]$SourceCapture.command } else { '' }
        diff = (Resolve-TranslatedDiffState -SourceCapture $SourceCapture)
        labviewExePath = $LabVIEWExePathValue
        labviewBitness = $LabVIEWBitnessValue
        environment = [ordered]@{
            cli = $cliNode
            container = [ordered]@{
                image = $Image
                sourceCapturePath = $CapturePathValue
            }
        }
    }
}

$scriptsRoot = Resolve-HostedCompareScriptsRoot
$runnerScript = Resolve-HostedCompareRunner -ScriptsRoot $scriptsRoot
$reportType = Resolve-HostedCompareReportType -ReportFormatValue $ReportFormat -RenderReportValue:$RenderReport
$reportExtension = Resolve-ReportExtension -ReportTypeValue $reportType
$outputDirResolved = Resolve-OutputDirectory -PathValue $OutputDir
$baseViResolved = Resolve-AbsolutePath -PathValue $BaseVi -BasePath (Get-Location).Path
$headViResolved = Resolve-AbsolutePath -PathValue $HeadVi -BasePath (Get-Location).Path
$reportPathResolved = Join-Path $outputDirResolved ("compare-report.{0}" -f $reportExtension)
$image = if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_NI_LINUX_IMAGE)) {
    'nationalinstruments/labview:2026q1-linux'
} else {
    $env:COMPAREVI_NI_LINUX_IMAGE.Trim()
}

New-Item -ItemType Directory -Path $outputDirResolved -Force | Out-Null

$niCapturePath = Join-Path $outputDirResolved 'ni-linux-container-capture.json'
$niStdOutPath = Join-Path $outputDirResolved 'ni-linux-container-stdout.txt'
$niStdErrPath = Join-Path $outputDirResolved 'ni-linux-container-stderr.txt'
$lvCapturePath = Join-Path $outputDirResolved 'lvcompare-capture.json'
$lvStdOutPath = Join-Path $outputDirResolved 'lvcompare-stdout.txt'
$lvStdErrPath = Join-Path $outputDirResolved 'lvcompare-stderr.txt'

$resolvedFlags = @(Resolve-HostedCompareFlags -FlagValues $Flags -ReplaceFlagsValue:$ReplaceFlags)
$runnerArgs = @{
    BaseVi = $baseViResolved
    HeadVi = $headViResolved
    Image = $image
    ReportPath = $reportPathResolved
    ReportType = $reportType
}
if ($null -ne $TimeoutSeconds -and [int]$TimeoutSeconds -gt 0) {
    $runnerArgs.TimeoutSeconds = [int]$TimeoutSeconds
}
if ($resolvedFlags.Count -gt 0) {
    $runnerArgs.Flags = @($resolvedFlags)
}
if ($Quiet.IsPresent) {
    $runnerArgs.HeartbeatSeconds = 30
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$runnerCapture = $null
$runnerExitCode = 0
$runnerErrorMessage = $null
Write-Host ("[hosted-linux-adapter] invoking-runner reportType={0} image={1} reportPath={2}" -f $reportType, $image, $reportPathResolved)
try {
    $runnerCapture = & $runnerScript @runnerArgs -PassThru
    $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    $runnerExitCode = if ($lastExit) { [int]$lastExit.Value } else { 0 }
} catch {
    $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    $runnerExitCode = if ($lastExit -and [int]$lastExit.Value -ne 0) { [int]$lastExit.Value } else { 2 }
    $runnerErrorMessage = $_.Exception.Message
} finally {
    $stopwatch.Stop()
}

if (-not $runnerCapture -and (Test-Path -LiteralPath $niCapturePath -PathType Leaf)) {
    try {
        $runnerCapture = Get-Content -LiteralPath $niCapturePath -Raw | ConvertFrom-Json -Depth 10
    } catch {
        $runnerCapture = $null
    }
}
if (-not $runnerCapture) {
    $runnerCapture = New-FallbackCapture `
        -ExitCode $runnerExitCode `
        -Image $image `
        -ReportPathValue $reportPathResolved `
        -Message $runnerErrorMessage
}
if ($runnerCapture.PSObject.Properties['exitCode'] -and $runnerCapture.exitCode -ne $null) {
    $runnerExitCode = [int]$runnerCapture.exitCode
}

Copy-OrWriteArtifact -SourcePath $niStdOutPath -DestinationPath $lvStdOutPath
Copy-OrWriteArtifact -SourcePath $niStdErrPath -DestinationPath $lvStdErrPath

$normalizedCapture = Convert-ToTranslatedCapture `
    -SourceCapture $runnerCapture `
    -Image $image `
    -BaseViPath $baseViResolved `
    -HeadViPath $headViResolved `
    -ReportPathValue $reportPathResolved `
    -CapturePathValue $niCapturePath `
    -StdOutPathValue $lvStdOutPath `
    -StdErrPathValue $lvStdErrPath `
    -ResolvedFlags $resolvedFlags `
    -ReportTypeValue $reportType `
    -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
    -LabVIEWBitnessValue $LabVIEWBitness `
    -LabVIEWExePathValue $LabVIEWExePath

$normalizedCapture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lvCapturePath -Encoding utf8

if ($runnerExitCode -ne 0) {
    exit $runnerExitCode
}
