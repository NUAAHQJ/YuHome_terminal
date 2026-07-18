param(
  [int]$Port = 1347
)

$client = [System.Net.Sockets.UdpClient]::new($Port)
$endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

Write-Host "[UDP] Listening on 0.0.0.0:$Port" -ForegroundColor Green
Write-Host "[UDP] Press Ctrl+C to stop."

try {
  while ($true) {
    $bytes = $client.Receive([ref]$endpoint)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $time = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$time] From $($endpoint.Address):$($endpoint.Port)"
    Write-Host $text
  }
}
finally {
  $client.Close()
}
