param(
  [switch]$Background,
  [int]$Port = 8787,
  [string]$ListenHost = "0.0.0.0",
  [string]$FileRoots = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateRoot = Join-Path $ProjectRoot ".cloudex-state"
$TokenFile = Join-Path $StateRoot "auth-token"
$StdoutLog = Join-Path $StateRoot "server.stdout.log"
$StderrLog = Join-Path $StateRoot "server.stderr.log"

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

if (-not $env:AUTH_TOKEN) {
  if (Test-Path $TokenFile) {
    $env:AUTH_TOKEN = (Get-Content $TokenFile -Raw).Trim()
  } else {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $env:AUTH_TOKEN = [Convert]::ToBase64String($bytes).Replace("+", "-").Replace("/", "_").TrimEnd("=")
    Set-Content -Path $TokenFile -Value $env:AUTH_TOKEN -NoNewline
  }
}

$env:HOST = $ListenHost
$env:PORT = "$Port"
$env:DEFAULT_CWD = $ProjectRoot
$env:FILE_ROOTS = if ($FileRoots) { $FileRoots } else { $ProjectRoot }
$env:CLOUDEX_STATE_DIR = $StateRoot

$node = (Get-Command node.exe).Source
$arguments = "apps/server/src/server.js"

if ($Background) {
  $process = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $ProjectRoot `
    -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog -WindowStyle Hidden -PassThru
  Write-Output "Cloudex PID: $($process.Id)"
  Write-Output "URL: http://127.0.0.1:$Port"
  Write-Output "Token: $env:AUTH_TOKEN"
  Write-Output "Logs: $StdoutLog / $StderrLog"
} else {
  Write-Output "Cloudex URL: http://$ListenHost`:$Port"
  Write-Output "Token: $env:AUTH_TOKEN"
  & $node $arguments
}
