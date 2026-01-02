#requires -Version 5.1
<
.SYNOPSIS
  Einfache PowerShell-Web-App, die Rechner im lokalen Netzwerk auflistet.
.DESCRIPTION
  Startet einen lokalen HTTP-Server und stellt eine Webseite bereit, die Hostname,
  IP-Adresse, MAC-Adresse und Betriebssystem anzeigt.
.PARAMETER Port
  Lokaler Port für den Webserver (Standard: 8080).
.EXAMPLE
  .\WebNetScan.ps1 -Port 8080
#>
param(
  [int]$Port = 8080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-SelfSignedSignature {
  $scriptPath = $PSCommandPath
  $signature = Get-AuthenticodeSignature -FilePath $scriptPath
  if ($signature.Status -eq 'Valid') {
    return
  }

  Write-Host "Signatur fehlt/ungültig. Erstelle Self-Signed Zertifikat..." -ForegroundColor Yellow
  $cert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {
    $_.Subject -eq 'CN=LocalPowerShellWebApp'
  } | Select-Object -First 1

  if (-not $cert) {
    $cert = New-SelfSignedCertificate -Subject 'CN=LocalPowerShellWebApp' -CertStoreLocation Cert:\CurrentUser\My
  }

  $sig = Set-AuthenticodeSignature -FilePath $scriptPath -Certificate $cert
  if ($sig.Status -ne 'Valid') {
    Write-Warning "Signieren fehlgeschlagen: $($sig.StatusMessage)"
  } else {
    Write-Host "Datei wurde erfolgreich signiert." -ForegroundColor Green
  }
}

function Get-PrimaryIPv4Interface {
  $ipInfo = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike '169.254*' -and $_.PrefixLength -gt 0 -and $_.InterfaceOperationalStatus -eq 'Up'
  } | Sort-Object -Property InterfaceMetric, AddressState | Select-Object -First 1

  if (-not $ipInfo) {
    throw 'Keine aktive IPv4-Schnittstelle gefunden.'
  }

  return $ipInfo
}

function ConvertTo-UInt32 {
  param([IPAddress]$Ip)
  $bytes = $Ip.GetAddressBytes()
  [Array]::Reverse($bytes)
  return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-UInt32 {
  param([UInt32]$Value)
  $bytes = [BitConverter]::GetBytes($Value)
  [Array]::Reverse($bytes)
  return [IPAddress]::new($bytes)
}

function Get-SubnetHosts {
  param(
    [IPAddress]$Address,
    [int]$PrefixLength
  )

  $mask = [UInt32]::MaxValue -shl (32 - $PrefixLength)
  $addrValue = ConvertTo-UInt32 -Ip $Address
  $network = $addrValue -band $mask
  $broadcast = $network -bor (-bnot $mask)

  $start = $network + 1
  $end = $broadcast - 1

  for ($i = $start; $i -le $end; $i++) {
    ConvertFrom-UInt32 -Value $i
  }
}

function Get-MacAddress {
  param([IPAddress]$Ip)

  $neighbor = Get-NetNeighbor -IPAddress $Ip.IPAddressToString -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($neighbor -and $neighbor.LinkLayerAddress -and $neighbor.LinkLayerAddress -ne '00-00-00-00-00-00') {
    return $neighbor.LinkLayerAddress
  }

  $arpLine = arp -a | Select-String -Pattern $Ip.IPAddressToString | Select-Object -First 1
  if ($arpLine) {
    $parts = $arpLine.ToString() -split '\s+'
    if ($parts.Length -ge 2) {
      return $parts[1]
    }
  }

  return 'Unbekannt'
}

function Get-OperatingSystem {
  param([string]$ComputerName)

  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
    return $os.Caption
  } catch {
    return 'Unbekannt (Zugriff verweigert oder offline)'
  }
}

function Scan-Network {
  $ipInfo = Get-PrimaryIPv4Interface
  $hosts = Get-SubnetHosts -Address ([IPAddress]$ipInfo.IPAddress) -PrefixLength $ipInfo.PrefixLength
  $results = @()

  foreach ($host in $hosts) {
    $ipString = $host.IPAddressToString
    $alive = Test-Connection -ComputerName $ipString -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction SilentlyContinue
    if (-not $alive) {
      continue
    }

    $hostname = 'Unbekannt'
    try {
      $entry = [System.Net.Dns]::GetHostEntry($ipString)
      if ($entry.HostName) {
        $hostname = $entry.HostName
      }
    } catch {
      $hostname = 'Unbekannt'
    }

    $mac = Get-MacAddress -Ip $host
    $osName = Get-OperatingSystem -ComputerName $ipString

    $results += [PSCustomObject]@{
      Hostname = $hostname
      IP       = $ipString
      Mac      = $mac
      OS       = $osName
    }
  }

  return $results
}

function Get-IndexHtml {
  @'
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Netzwerk-Scan</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; }
    h1 { margin-bottom: 1rem; }
    button { padding: 0.5rem 1rem; }
    table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
    th, td { border: 1px solid #ddd; padding: 0.5rem; text-align: left; }
    th { background: #f3f3f3; }
    .status { margin-top: 1rem; }
  </style>
</head>
<body>
  <h1>Netzwerk-Scan</h1>
  <button id="scanButton">Scan starten</button>
  <div class="status" id="status"></div>
  <table>
    <thead>
      <tr>
        <th>Hostname</th>
        <th>IP-Adresse</th>
        <th>MAC-Adresse</th>
        <th>Betriebssystem</th>
      </tr>
    </thead>
    <tbody id="results"></tbody>
  </table>

  <script>
    const scanButton = document.getElementById('scanButton');
    const status = document.getElementById('status');
    const results = document.getElementById('results');

    scanButton.addEventListener('click', async () => {
      status.textContent = 'Scanne Netzwerk...';
      results.innerHTML = '';

      try {
        const response = await fetch('/api/scan');
        const data = await response.json();
        if (!data.length) {
          status.textContent = 'Keine Geräte gefunden.';
          return;
        }

        for (const item of data) {
          const row = document.createElement('tr');
          row.innerHTML = `
            <td>${item.Hostname}</td>
            <td>${item.IP}</td>
            <td>${item.Mac}</td>
            <td>${item.OS}</td>
          `;
          results.appendChild(row);
        }

        status.textContent = `Gefundene Geräte: ${data.length}`;
      } catch (err) {
        status.textContent = 'Fehler beim Scan.';
      }
    });
  </script>
</body>
</html>
'@
}

Ensure-SelfSignedSignature

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Web-App gestartet: http://localhost:$Port" -ForegroundColor Green
Write-Host 'Zum Beenden Strg+C drücken.'

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    if ($request.Url.AbsolutePath -eq '/api/scan') {
      $data = Scan-Network | ConvertTo-Json -Depth 4
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
      $response.ContentType = 'application/json; charset=utf-8'
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
      $response.OutputStream.Close()
      continue
    }

    $html = Get-IndexHtml
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $response.ContentType = 'text/html; charset=utf-8'
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
