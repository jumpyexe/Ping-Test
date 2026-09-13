# Ping-Test

A Windows PowerShell script for quickly checking local, gateway, DNS, and
external connectivity. It supports Windows PowerShell 3.0 and later.

## Usage

Run the script from a PowerShell prompt:

```powershell
.\pingtest.ps1
```

The script discovers IP-enabled adapters, runs ping and route diagnostics, and
tests both the system resolver and each configured DNS server. Windows chooses
the route for network probes; results grouped beneath an adapter therefore
describe its discovered configuration and do not guarantee that every probe
was transmitted through that adapter.

By default, the transcript is written under `C:\Logs\Maintenance`. If that
location cannot be created or written, diagnostics continue without a
transcript. The tests contact `9.9.9.9` and resolve `cloudflare.com`.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | All recorded checks succeeded. |
| `1` | The diagnostic run could not be completed. |
| `2` | The run completed, but one or more checks failed or were skipped. |
