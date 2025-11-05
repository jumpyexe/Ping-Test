# Purpose: Dynamically test local, gateway, DNS, and external connectivity + DNS resolution.
# Inputs: none (auto-detects active network adapter)

function Get-LastIpv4Address {
    param(
        [string[]]$Text
    )

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

$resolveDnsNameCmd = Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue
$tracertCmd        = Get-Command -Name tracert -ErrorAction SilentlyContinue

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
    }
    else {
        Write-ColoredMessage -Message $FailureMessage -Color 'Red'
    }
}

function Invoke-DnsResolutionTest {
    param(
        [string]$HostName,
        [string]$Description,
        [string]$Server
    )

    Write-ColoredMessage -Message "Resolving $HostName using $Description..."

    if ($resolveDnsNameCmd) {
        try {
            $resolveParams = @{ Name = $HostName; ErrorAction = 'Stop' }
            if ($Server) { $resolveParams.Server = $Server }

            $dnsResult = Resolve-DnsName @resolveParams
            $record = $dnsResult | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
            if (-not $record) { $record = $dnsResult | Select-Object -First 1 }

            if ($record.IPAddress) {
                Write-ColoredMessage -Message "  Resolution successful: $($record.IPAddress)" -Color 'Green'
            }
            else {
                Write-ColoredMessage -Message '  Resolution completed but no IP address returned.' -Color 'Yellow'
            }
        }
        catch {
            Write-ColoredMessage -Message "  Resolution failed: $($_.Exception.Message)" -Color 'Red'
        }
    }
    else {
        $nslookupArgs = @($HostName)
        if ($Server) { $nslookupArgs += $Server }

        $output = & nslookup @nslookupArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $lines = (@($output) -join "`n") -split "`r?`n"
            $ipAddress = Get-LastIpv4Address -Text $lines
            if ($ipAddress) {
                Write-ColoredMessage -Message "  Resolution successful: $ipAddress" -Color 'Green'
            }
            else {
                Write-ColoredMessage -Message '  Resolution completed but no IPv4 address found.' -Color 'Yellow'
            }
        }
        else {
            Write-ColoredMessage -Message '  Resolution failed via nslookup.' -Color 'Red'
            if ($output) {
                $message = if ($output -is [System.Array]) { $output -join "`n" } else { [string]$output }
                Write-ColoredMessage -Message $message
            }
        }
    }
}

$adapter = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object {
    $_.IPEnabled -and $_.DefaultIPGateway
} | Select-Object -First 1

if (-not $adapter) {
    exit 1
}

$interfaceName = if ($adapter.NetConnectionID) { $adapter.NetConnectionID } else { $adapter.Description }
$localIP      = ($adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
$gateway      = ($adapter.DefaultIPGateway | Select-Object -First 1)
$dns          = ($adapter.DNSServerSearchOrder | Select-Object -First 1)
$external     = '8.8.8.8'
$testHost     = 'microsoft.com'

Write-ColoredMessage -Message "Testing connectivity for adapter $interfaceName...`n" -Color 'Cyan'

# Connectivity test: ping loopback, local interface, gateway, DNS, and an external endpoint.
$targets = @(@{Name = 'Localhost'; Addr = '127.0.0.1'})
if ($localIP)   { $targets += @{Name = 'Local';    Addr = $localIP} }
if ($gateway)   { $targets += @{Name = 'Gateway';  Addr = $gateway} }
if ($dns)       { $targets += @{Name = 'DNS';      Addr = $dns} }
$targets += @{Name = 'External'; Addr = $external}

foreach ($t in $targets) {
    Write-ColoredMessage -Message "Pinging $($t.Name): $($t.Addr)"
    $result = Test-Connection -Count 2 -Quiet -ComputerName $t.Addr
    Write-TestOutcome -Succeeded $result
}

if ($tracertCmd) {
    # Route test: capture network path to each connectivity target and the DNS host.
    # Skip reverse DNS and shrink hop timeout to speed up tracert output.
    $tracertArgs = @('-d', '-w', '1500')
    Write-ColoredMessage -Message "`nTracing routes for tested targets..." -Color 'Cyan'
    foreach ($t in $targets) {
        Write-ColoredMessage -Message "`nTracing $($t.Name): $($t.Addr)"
        & $tracertCmd.Source @tracertArgs $t.Addr
    }

    Write-ColoredMessage -Message "`nTracing DNS resolution host target: $testHost" -Color 'Cyan'
    & $tracertCmd.Source @tracertArgs $testHost
}
else {
    Write-ColoredMessage -Message "`ntracert command not available. Skipping route traces." -Color 'Yellow'
}

Write-ColoredMessage -Message "`nTesting DNS resolution path..." -Color 'Cyan'

# DNS test: confirm default system resolver and adapter-provided server both succeed.
Invoke-DnsResolutionTest -HostName $testHost -Description 'system DNS' -Server $null

if ($dns) {
    Invoke-DnsResolutionTest -HostName $testHost -Description "explicit DNS server $dns" -Server $dns
}
else {
    Write-ColoredMessage -Message 'No DNS server detected from adapter configuration. Skipping explicit DNS resolution test.' -Color 'Yellow'
}

Write-ColoredMessage -Message "`nNetwork test completed." -Color 'Cyan'
