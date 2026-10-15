<#
.SYNOPSIS
  Corre el benchmark en Windows + Docker Desktop con UN SOLO comando.

.DESCRIPTION
  Abre un túnel SSH al model server del clúster y lanza el contenedor del
  benchmark. El contenedor usa red bridge y alcanza el túnel (que vive en el
  localhost de Windows) a través de host.docker.internal. El túnel se cierra solo
  al terminar.

  SETUP (una sola vez):
    1. Docker Desktop instalado y CORRIENDO, con backend WSL2 y GPU habilitada
       (Settings > Resources > WSL Integration y GPU). Sin backend WSL2 no hay
       --gpus: tendrías que usar render: cpu (lento).
    2. uv instalado en Windows:  winget install astral-sh.uv   (o irm https://astral.sh/uv/install.ps1 | iex)
    3. Este repo clonado y, desde su raíz:  uv sync
    4. Acceso SSH a kraken desde Windows (ssh.exe ya viene en Windows). Tu llave
       y ~/.ssh/config del clúster deben estar en C:\Users\<tu-usuario>\.ssh\.

  USO (PowerShell, desde la raíz del repo):
    .\scripts\run_benchmark.ps1
    .\scripts\run_benchmark.ps1 -Port 8001 -BenchCfg configs/benchmarks/libero/spatial.yaml
    .\scripts\run_benchmark.ps1 -ClusterNode yodaxico     # nodo que imprime el log del job del modelo

  Primero, en el clúster:  sbatch scripts/model_server.sbatch   (anota el nodo del log)
#>
param(
  [string]$BenchCfg = "configs/benchmarks/libero/smoke_test.yaml",
  [int]$Port = 8000,
  [string]$ClusterNode = "yodaxico",
  [string]$LoginNode = "kraken",
  [Parameter(ValueFromRemainingArguments = $true)] $Extra
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

# Red bridge + host.docker.internal (lo entiende el harness parcheado).
$env:VLA_EVAL_DOCKER_NETWORK = "bridge"
$serverUrl = "ws://host.docker.internal:$Port"

Write-Host "[+] Benchmark:            $BenchCfg"
Write-Host "[+] Model server (túnel): $serverUrl"

# Docker Desktop debe estar corriendo.
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker no responde. Abre Docker Desktop y reintenta." }

# Túnel SSH en background: localhost:Port (Windows) -> (vía login) -> nodo:Port.
# Enlaza en loopback; Docker Desktop alcanza ese 127.0.0.1 vía host.docker.internal.
# Si tu Docker Desktop no lo alcanzara, cambia a:  "-L","0.0.0.0:${Port}:${ClusterNode}:${Port}"
Write-Host "[+] Abriendo túnel: localhost:$Port -> ${ClusterNode}:$Port (vía $LoginNode)"
# -NoNewWindow deja la salida de ssh en esta consola, así ves cualquier prompt
# (host key / contraseña) o error en vez de que se cuelgue oculto.
$sshArgs = @(
  "-N",
  "-o", "ConnectTimeout=10",
  "-o", "ServerAliveInterval=30",
  "-o", "StrictHostKeyChecking=accept-new",
  "-L", "${Port}:${ClusterNode}:${Port}",
  "$LoginNode"
)
$tunnel = Start-Process ssh -PassThru -NoNewWindow -ArgumentList $sshArgs

try {
  # Esperar al model server (/health solo responde 200 una vez cargado el modelo).
  # Usamos curl.exe contra 127.0.0.1 (evita el localhost IPv6 de Windows).
  Write-Host "[+] Esperando al model server en http://127.0.0.1:$Port/health ..."
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    if ($tunnel.HasExited) { throw "El túnel SSH murió (¿acceso a $LoginNode?)." }
    $body = (& curl.exe -s --max-time 3 "http://127.0.0.1:$Port/health" 2>$null)
    $code = $LASTEXITCODE
    # Listo si responde el body, o si la conexión llegó al server pero OpenSSH en
    # Windows cerró el forward con un reset (curl 56) tras el GET: quirk benigno,
    # el WebSocket del benchmark (conexión larga) no se ve afectado.
    if (($body -match '"status"') -or ($code -eq 56)) { $ready = $true; break }
    Start-Sleep -Seconds 3
  }
  if (-not $ready) {
    throw "Sin respuesta en 127.0.0.1:$Port. ¿El job del modelo está vivo y el nodo es '$ClusterNode'?"
  }
  Write-Host "[+] Túnel OK, model server alcanzable."

  # Lanzar el benchmark. --yes evita el prompt del docker pull. $Extra se reenvía.
  Write-Host "[+] Corriendo benchmark..."
  uv run vla-eval run -c $BenchCfg --server-url $serverUrl --yes @Extra
}
finally {
  if (-not $tunnel.HasExited) {
    Write-Host "[+] Cerrando túnel (pid $($tunnel.Id))"
    Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "[+] Listo. Revisa el recording en: results\recording-*.sqlite"
