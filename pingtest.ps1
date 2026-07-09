# Purpose: Dynamically test local, gateway, DNS, and external connectivity with detailed network pathing + DNS resolution.
# Inputs: none (auto-detects active network adapters)

function Write-ColoredMessage {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )

    Write-Host $Message -ForegroundColor $Color
}

function Write-TestOutcome {
    param(
        [bool]$Succeeded,
        [string]$SuccessMessage = '  OK',
        [string]$FailureMessage = '  FAIL'
    )

    if ($Succeeded) {
        Write-ColoredMessage -Message $SuccessMessage -Color 'Green'
        return
    }

    Write-ColoredMessage -Message $FailureMessage -Color 'Red'
}

function Add-Issue {
    param(
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Issues,

        [Parameter(Mandatory)]
        [string]$Issue
    )

    [void]$Issues.Add($Issue)
}

function Start-NetworkTestLog {
    param(
        [string]$LogDirectory = 'C:\Logs\Maintenance'
    )

    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $logPath = Join-Path -Path $LogDirectory -ChildPath "NetworkTest-$timestamp.log"
        Start-Transcript -Path $logPath -Force -ErrorAction Stop | Out-Null
        Write-ColoredMessage -Message "Logging to $logPath" -Color 'Cyan'
        return $logPath
    }
    catch {
        throw "Unable to start log in $LogDirectory`: $($_.Exception.Message)"
    }
}

function Get-OptionalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        return Get-Command -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-LastIpv4Address {
    param(
        [string[]]$Text
    )

    try {
        $ipv4Addresses = @()
        foreach ($line in $Text) {
            $matches = [regex]::Matches($line, '(\d{1,3}(?:\.\d{1,3}){3})')
            foreach ($match in $matches) {
                $segments = $match.Value.Split('.') | ForEach-Object { [int]$_ }
                if ($segments -and ($segments | Where-Object { $_ -gt 255 }).Count -eq 0) {
                    $ipv4Addresses += $match.Value
                }
            }
        }

        return ($ipv4Addresses | Select-Object -Last 1)
    }
    catch {
        throw "Unable to parse IPv4 address from DNS output: $($_.Exception.Message)"
    }
}

function Get-ActiveNetworkAdapters {
    try {
        $adapters = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object {
                $_.IPEnabled -and
                ($_.DefaultIPGateway -or $_.IPAddress) -and
                ($_.NetConnectionID -or $_.Description)
            })

        if ($adapters.Count -eq 0) {
            throw 'No active network adapters were found.'
        }

        return $adapters
    }
    catch {
        throw "Unable to detect active network adapters: $($_.Exception.Message)"
    }
}

function Add-TargetIfPresent {
    param(
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Targets,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Address
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Address)) {
            Write-ColoredMessage -Message "Skipping $Name target because no address was detected." -Color 'Yellow'
            return
        }

        [void]$Targets.Add(@{ Name = $Name; Addr = $Address })
    }
    catch {
        Write-ColoredMessage -Message "Failed to add $Name target: $($_.Exception.Message)" -Color 'Red'
    }
}

function Invoke-PingTest {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Target
    )

    try {
        Write-ColoredMessage -Message "Pinging $($Target.Name): $($Target.Addr)"
        $result = Test-Connection -Count 2 -Quiet -ComputerName $Target.Addr -ErrorAction Stop
        Write-TestOutcome -Succeeded $result
        return [bool]$result
    }
    catch {
        Write-TestOutcome -Succeeded $false -FailureMessage "  FAIL: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-TraceRoute {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$Command,

        [Parameter(Mandatory)]
        [string]$TargetName,

        [Parameter(Mandatory)]
        [string]$Address,

        [int]$MaxHops = 15
    )

    try {
        Write-ColoredMessage -Message "`nTracing ${TargetName}: $Address" -Color 'Cyan'
        $output = @(& $Command.Source '-d' '-h' $MaxHops '-w' '1500' $Address 2>&1)
        $exitCode = $LASTEXITCODE

        foreach ($line in $output) {
            Write-ColoredMessage -Message ([string]$line)
        }

        $outputText = $output -join "`n"
        $hasTimeout = $outputText -match 'Request timed out|\*\s+\*\s+\*'
        $traceComplete = $outputText -match 'Trace complete'

        if ($exitCode -ne 0) {
            throw "tracert exited with code $exitCode."
        }

        if (-not $traceComplete) {
            Write-ColoredMessage -Message "  TRACE FAILED: destination not reached within max $MaxHops hops." -Color 'Red'
            return $false
        }

        if ($hasTimeout) {
            Write-ColoredMessage -Message "  TRACE OK: completed within max $MaxHops hops; one or more intermediate hops did not reply." -Color 'Green'
            return $true
        }

        Write-ColoredMessage -Message "  TRACE OK: completed within max $MaxHops hops." -Color 'Green'
        return $true
    }
    catch {
        Write-ColoredMessage -Message "  TRACE FAILED: $($_.Exception.Message)" -Color 'Red'
        return $false
    }
}

function Invoke-DnsResolutionTest {
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [string]$Description,

        [string]$Server
    )

    Write-ColoredMessage -Message "Resolving $HostName using $Description..."

    try {
        $resolveParams = @{ Name = $HostName; ErrorAction = 'Stop' }
        if ($Server) { $resolveParams.Server = $Server }

        $dnsResult = Resolve-DnsName @resolveParams
        $record = $dnsResult | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
        if (-not $record) { $record = $dnsResult | Select-Object -First 1 }

        if (-not $record.IPAddress) {
            throw 'Resolution completed but no IP address was returned.'
        }

        Write-ColoredMessage -Message "  Resolution successful: $($record.IPAddress)" -Color 'Green'
        return $true
    }
    catch {
        Write-ColoredMessage -Message "  Resolve-DnsName failed: $($_.Exception.Message)" -Color 'Yellow'
        return (Invoke-NsLookupResolutionTest -HostName $HostName -Description $Description -Server $Server)
    }
}

function Invoke-NsLookupResolutionTest {
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [string]$Description,

        [string]$Server
    )

    try {
        $nslookupArgs = @($HostName)
        if ($Server) { $nslookupArgs += $Server }

        $output = & nslookup @nslookupArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = if ($output) { (@($output) -join "`n") } else { 'nslookup returned no output.' }
            throw $message
        }

        $lines = (@($output) -join "`n") -split "`r?`n"
        $ipAddress = Get-LastIpv4Address -Text $lines
        if (-not $ipAddress) {
            throw 'Resolution completed but no IPv4 address was found.'
        }

        Write-ColoredMessage -Message "  Resolution successful via nslookup: $ipAddress" -Color 'Green'
        return $true
    }
    catch {
        Write-ColoredMessage -Message "  Resolution failed using $Description`: $($_.Exception.Message)" -Color 'Red'
        return $false
    }
}

function Invoke-GlobalConnectivityTest {
    param(
        [System.Management.Automation.CommandInfo]$TracertCommand
    )

    $issues = [System.Collections.ArrayList]::new()

    try {
        Write-ColoredMessage -Message "`n============================================================" -Color 'Cyan'
        Write-ColoredMessage -Message 'Global local host check' -Color 'Cyan'
        Write-ColoredMessage -Message "============================================================`n" -Color 'Cyan'

        $localhostTarget = @{ Name = 'Localhost'; Addr = '127.0.0.1' }
        if (-not (Invoke-PingTest -Target $localhostTarget)) {
            Add-Issue -Issues $issues -Issue 'localhost ping failed'
        }

        try {
            if (-not $TracertCommand) {
                throw 'tracert command not available.'
            }

            if (-not (Invoke-TraceRoute -Command $TracertCommand -TargetName $localhostTarget.Name -Address $localhostTarget.Addr -MaxHops 15)) {
                Add-Issue -Issues $issues -Issue 'localhost trace failed'
            }
        }
        catch {
            Write-ColoredMessage -Message "`n$($_.Exception.Message) Skipping localhost route trace." -Color 'Yellow'
            Add-Issue -Issues $issues -Issue 'localhost trace skipped'
        }
    }
    catch {
        Write-ColoredMessage -Message "Global localhost check failed: $($_.Exception.Message)" -Color 'Red'
        Add-Issue -Issues $issues -Issue 'localhost check failed'
    }

    return [pscustomobject]@{
        Name = 'Global'
        Issues = @($issues)
    }
}

function Invoke-AdapterConnectivityTest {
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [System.Management.Automation.CommandInfo]$TracertCommand,

        [Parameter(Mandatory)]
        [string]$External,

        [Parameter(Mandatory)]
        [string]$TestHost
    )

    $issues = [System.Collections.ArrayList]::new()
    $interfaceName = if ($Adapter.NetConnectionID) { $Adapter.NetConnectionID } else { $Adapter.Description }

    try {
        $localIP = ($Adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
        $gateway = ($Adapter.DefaultIPGateway | Select-Object -First 1)
        $dnsServers = @($Adapter.DNSServerSearchOrder | Where-Object { $_ })
        $primaryDns = $dnsServers | Select-Object -First 1

        Write-ColoredMessage -Message "`n============================================================" -Color 'Cyan'
        Write-ColoredMessage -Message "Testing connectivity for adapter $interfaceName" -Color 'Cyan'
        Write-ColoredMessage -Message "Description: $($Adapter.Description)"
        Write-ColoredMessage -Message "Local IPv4: $localIP"
        Write-ColoredMessage -Message "Gateway: $gateway"
        Write-ColoredMessage -Message "DNS servers: $($dnsServers -join ', ')"
        Write-ColoredMessage -Message "External endpoint: $External"
        Write-ColoredMessage -Message "DNS test host: $TestHost"
        Write-ColoredMessage -Message "============================================================`n" -Color 'Cyan'

        # Adapter-specific connectivity test: local interface, gateway, DNS, and an external endpoint.
        $targets = [System.Collections.ArrayList]::new()
        Add-TargetIfPresent -Targets $targets -Name 'Local' -Address $localIP
        Add-TargetIfPresent -Targets $targets -Name 'Gateway' -Address $gateway
        foreach ($dnsServer in $dnsServers) {
            Add-TargetIfPresent -Targets $targets -Name 'DNS' -Address $dnsServer
        }
        Add-TargetIfPresent -Targets $targets -Name 'External' -Address $External

        foreach ($target in $targets) {
            if (-not (Invoke-PingTest -Target $target)) {
                Add-Issue -Issues $issues -Issue "$($target.Name) ping failed"
            }
        }

        try {
            if (-not $TracertCommand) {
                throw 'tracert command not available.'
            }

            Write-ColoredMessage -Message "`nTracing routes for tested targets..." -Color 'Cyan'
            foreach ($target in $targets) {
                if (-not (Invoke-TraceRoute -Command $TracertCommand -TargetName $target.Name -Address $target.Addr -MaxHops 15)) {
                    Add-Issue -Issues $issues -Issue "$($target.Name) trace failed"
                }
            }

            if (-not (Invoke-TraceRoute -Command $TracertCommand -TargetName 'DNS resolution host target' -Address $TestHost -MaxHops 15)) {
                Add-Issue -Issues $issues -Issue "$TestHost trace failed"
            }
        }
        catch {
            Write-ColoredMessage -Message "`n$($_.Exception.Message) Skipping route traces." -Color 'Yellow'
            Add-Issue -Issues $issues -Issue 'route traces skipped'
        }

        Write-ColoredMessage -Message "`nTesting DNS resolution path..." -Color 'Cyan'

        # DNS test: confirm default system resolver and adapter-provided servers all succeed.
        if (-not (Invoke-DnsResolutionTest -HostName $TestHost -Description 'system DNS' -Server $null)) {
            Add-Issue -Issues $issues -Issue 'system DNS resolution failed'
        }

        try {
            if (-not $primaryDns) {
                throw 'No DNS server detected from adapter configuration.'
            }

            foreach ($dnsServer in $dnsServers) {
                if (-not (Invoke-DnsResolutionTest -HostName $TestHost -Description "explicit DNS server $dnsServer" -Server $dnsServer)) {
                    Add-Issue -Issues $issues -Issue "DNS resolution failed via $dnsServer"
                }
            }
        }
        catch {
            Write-ColoredMessage -Message "$($_.Exception.Message) Skipping explicit DNS resolution test." -Color 'Yellow'
            Add-Issue -Issues $issues -Issue 'explicit DNS resolution skipped'
        }
    }
    catch {
        Write-ColoredMessage -Message "Adapter test failed: $($_.Exception.Message)" -Color 'Red'
        Add-Issue -Issues $issues -Issue 'adapter test failed'
    }

    return [pscustomobject]@{
        Name = $interfaceName
        Issues = @($issues)
    }
}

function Write-OneLineSummary {
    param(
        [Parameter(Mandatory)]
        [object[]]$Results
    )

    $parts = foreach ($result in $Results) {
        if ($result.Issues.Count -eq 0) {
            "$($result.Name): OK"
        }
        else {
            "$($result.Name): $($result.Issues -join ', ')"
        }
    }

    Write-ColoredMessage -Message "`nSUMMARY: $($parts -join '; ')" -Color 'Cyan'
}

$logPath = $null
try {
    $logPath = Start-NetworkTestLog
    $tracertCmd = Get-OptionalCommand -Name 'tracert'
    $adapters = @(Get-ActiveNetworkAdapters)
    $external = '9.9.9.9'  # Quad9 public DNS as a reliable external endpoint for connectivity testing.
    $testHost = 'cloudflare.com'  # A well-known domain for testing DNS resolution.
    $results = [System.Collections.ArrayList]::new()

    Write-ColoredMessage -Message "Network test started. Active adapters detected: $($adapters.Count)" -Color 'Cyan'

    [void]$results.Add((Invoke-GlobalConnectivityTest -TracertCommand $tracertCmd))

    foreach ($adapter in $adapters) {
        [void]$results.Add((Invoke-AdapterConnectivityTest -Adapter $adapter -TracertCommand $tracertCmd -External $external -TestHost $testHost))
    }

    Write-OneLineSummary -Results @($results)
    Write-ColoredMessage -Message "`nNetwork test completed." -Color 'Cyan'
    Write-ColoredMessage -Message "Log saved to $logPath" -Color 'Cyan'
}
catch {
    Write-ColoredMessage -Message "Network test failed: $($_.Exception.Message)" -Color 'Red'
    exit 1
}
finally {
    if ($logPath) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-ColoredMessage -Message "Unable to stop transcript: $($_.Exception.Message)" -Color 'Yellow'
        }
    }
}