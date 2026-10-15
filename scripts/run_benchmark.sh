#!/bin/bash
# PARTE 2 de 2: BENCHMARK en la máquina del benchmark (con Docker).
#
# Corre el benchmark en Docker y lo conecta al model server del clúster a través
# de un túnel SSH (lo abre este script si le das CLUSTER_NODE, o uno que tengas
# abierto aparte). El contenedor usa --network host, así que `localhost:$PORT`
# dentro del contenedor cae en el extremo local del túnel y, vía kraken, llega al
# nodo de cómputo.
#
# -------------------------------------------------------------------------
# CORRER EN TU NOTEBOOK WINDOWS (i7 / RTX 2050): usa WSL2, NO Windows nativo.
#   El harness lanza el contenedor con `--network host`, que en Docker Desktop
#   NO comparte el localhost del host → el túnel no sería visible. Instala
#   Docker Engine NATIVO dentro de WSL2 (no Docker Desktop) + nvidia-container-
#   toolkit, clona el repo dentro de WSL2 y corre este script ahí. La GPU se
#   pasa por el driver WSL de NVIDIA.
# -------------------------------------------------------------------------
#
# Requisitos en esta máquina (dentro de WSL2 si es Windows):
#   - Docker Engine + NVIDIA Container Toolkit (rendering en GPU).
#   - El repo clonado con `uv sync` hecho.
#   - Acceso SSH a kraken (para el túnel).
#
# Uso:
#   # A) El script abre el túnel solo (todo en una máquina):
#   CLUSTER_NODE=yodaxico scripts/run_benchmark.sh
#
#   # B) Ya tienes el túnel abierto en otra terminal:
#   scripts/run_benchmark.sh
#
#   # Overrides:
#   BENCH_CFG=configs/benchmarks/libero/spatial.yaml CLUSTER_NODE=yodaxico scripts/run_benchmark.sh
#   PORT=8001 CLUSTER_NODE=yodaxico scripts/run_benchmark.sh
#   CLUSTER_NODE=yodaxico scripts/run_benchmark.sh --record-video   # args extra -> `vla-eval run`

set -euo pipefail

# Raíz del repo = carpeta padre de este script (portable entre máquinas).
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCH_CFG="${BENCH_CFG:-configs/benchmarks/libero/smoke_test.yaml}"
PORT="${PORT:-8000}"
SERVER_URL="${SERVER_URL:-ws://localhost:${PORT}}"

# Para abrir el túnel automáticamente, define CLUSTER_NODE con el nodo que imprime
# el log del job de la PARTE 1 (p.ej. yodaxico). Si lo dejas vacío, el script
# asume que ya hay un túnel abierto en otra terminal.
CLUSTER_NODE="${CLUSTER_NODE:-}"
LOGIN_NODE="${LOGIN_NODE:-kraken}"

cd "$REPO"

# uv en el PATH si está instalado para el usuario.
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"

echo "[$(date)] Repo: $REPO"
echo "[$(date)] Benchmark: $BENCH_CFG"
echo "[$(date)] Model server (vía túnel): $SERVER_URL"

# Docker es imprescindible en esta máquina.
if ! docker info >/dev/null 2>&1; then
  echo "[$(date)] ERROR: Docker no está disponible aquí (en Windows: úsalo dentro de WSL2)." >&2
  exit 1
fi

# El server expone HTTP y WebSocket en el mismo puerto; /health solo responde 200
# una vez cargado el modelo, así que comprueba de una el túnel + el server listo.
reachable() { curl -s --max-time 3 "http://localhost:${PORT}/health" >/dev/null; }

# Si el script abre el túnel, lo cierra al terminar.
TUNNEL_PID=""
cleanup() {
  if [ -n "$TUNNEL_PID" ]; then
    echo "[$(date)] Cerrando túnel SSH (pid $TUNNEL_PID)"
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! reachable; then
  if [ -n "$CLUSTER_NODE" ]; then
    echo "[$(date)] Abriendo túnel: localhost:${PORT} -> ${CLUSTER_NODE}:${PORT} (vía ${LOGIN_NODE})"
    ssh -N -L "localhost:${PORT}:${CLUSTER_NODE}:${PORT}" "$LOGIN_NODE" &
    TUNNEL_PID=$!
    echo "[$(date)] Esperando a que el túnel + model server respondan ..."
    for _ in $(seq 1 30); do
      reachable && break
      kill -0 "$TUNNEL_PID" 2>/dev/null || { echo "[$(date)] ERROR: el túnel SSH murió." >&2; exit 1; }
      sleep 2
    done
  fi
fi

if ! reachable; then
  echo "[$(date)] ERROR: no hay respuesta en localhost:${PORT}." >&2
  echo "            Define CLUSTER_NODE=<nodo> para que el script abra el túnel," >&2
  echo "            o ábrelo tú:  ssh -N -L localhost:${PORT}:<nodo>:${PORT} ${LOGIN_NODE}" >&2
  exit 1
fi
echo "[$(date)] Túnel OK, model server alcanzable."

# Lanzar el benchmark apuntando al server remoto. --yes evita el prompt del
# docker pull. Los argumentos extra ("$@") se reenvían a `vla-eval run`.
echo "[$(date)] Corriendo benchmark..."
uv run vla-eval run -c "$BENCH_CFG" --server-url "$SERVER_URL" --yes "$@"

echo "[$(date)] Listo. Revisa el recording en: $REPO/results/recording-*.sqlite"
