# Purpose: Dynamically test local, gateway, DNS, and external connectivity + DNS resolution.
# Inputs: none (auto-detects active network adapter)

$adapter = Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq "Up"
}

if (-not $adapter) {
    Write-Host "No active adapter with default gateway found." -ForegroundColor Yellow
    return
}

$localIP   = $adapter.IPv4Address.IPAddress
$gateway   = $adapter.IPv4DefaultGateway.NextHop
$dns       = $adapter.DNSServer.ServerAddresses | Select-Object -First 1
$external  = "8.8.8.8"
$testHost  = "microsoft.com"

Write-Host "Testing connectivity for adapter $($adapter.InterfaceAlias)...`n"

$targets = @(
    @{Name="Local";    Addr=$localIP},
    @{Name="Gateway";  Addr=$gateway},
    @{Name="DNS";      Addr=$dns},
    @{Name="External"; Addr=$external}
)

foreach ($t in $targets) {
    Write-Host "Pinging $($t.Name): $($t.Addr)"
    $result = Test-Connection -Count 2 -Quiet -ComputerName $t.Addr
    if ($result) { Write-Host "  OK" -ForegroundColor Green }
    else         { Write-Host "  FAIL" -ForegroundColor Red }
}

Write-Host "`nTesting DNS resolution path..." -ForegroundColor Cyan

try {
    Write-Host "Resolving $testHost using system DNS..."
    $dnsResult = Resolve-DnsName $testHost -ErrorAction Stop
    Write-Host "  Resolution successful: $($dnsResult[0].IPAddress)" -ForegroundColor Green
}
catch {
    Write-Host "  Resolution failed using system DNS." -ForegroundColor Red
}

try {
    Write-Host "Resolving $testHost using explicit DNS server $dns..."
    $dnsResultExplicit = Resolve-DnsName $testHost -Server $dns -ErrorAction Stop
    Write-Host "  Resolution via $dns successful: $($dnsResultExplicit[0].IPAddress)" -ForegroundColor Green
}
catch {
    Write-Host "  Resolution failed via DNS server $dns." -ForegroundColor Red
}

Write-Host "`nNetwork test completed." -ForegroundColor Cyan