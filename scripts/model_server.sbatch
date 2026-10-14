#!/bin/bash
# Lado MODELO (clúster): levanta SOLO el model server en la GPU del nodo y
# publica el comando de túnel SSH para que el benchmark —en OTRA máquina— se
# conecte por WebSocket. El benchmark NO corre aquí (ver scripts/run_benchmark.sh).
#
# Flujo:
#   1) sbatch scripts/model_server.sbatch        # cae en yodaxico, levanta el serve
#   2) el job imprime en su log el comando de túnel SSH ya resuelto
#   3) en la máquina del benchmark: abres el túnel y corres scripts/run_benchmark.sh
#
# Uso:   sbatch scripts/model_server.sbatch
#        PORT=8000 MODEL_CFG=configs/model_servers/xvla/libero.yaml sbatch scripts/model_server.sbatch
# Logs:  slurm/logs/vla-model.log
#
# Nota GPU: yodaxico tiene GTX 1080 Ti (11 GB). X-VLA (0.9B) cabe de sobra;
# OpenVLA-7B / CogACT NO caben en 11 GB.

#SBATCH --job-name=vla-model
#SBATCH --comment="Model server (X-VLA) para evaluación remota: el benchmark corre en otra máquina y se conecta por túnel SSH"
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=diego.toledo@uc.cl
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=24gb
#SBATCH --partition=ialab-low-unlimit     # verifica con: sinfo -N -l
#SBATCH --qos=debug                        # debug suele topar en 1h; para runs largos sube --time y cambia --qos
#SBATCH --gres=gpu:1
#SBATCH --nodelist=yodaxico
#SBATCH --output=slurm/logs/%x.log
#SBATCH --time=1:00:00

set -euo pipefail

REPO=/mnt-homes/wapol/asoto/diegoftpxd/vla-evaluation-harness
cd "$REPO"

# uv debe estar en el PATH (instalado en ~/.local/bin por el instalador oficial).
[ -f "$HOME/.local/bin/env" ] && source "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"

# --- Parámetros (configurables por entorno) ----------------------------------
PORT="${PORT:-8000}"
MODEL_CFG="${MODEL_CFG:-configs/model_servers/xvla/libero.yaml}"
LOGIN_HOST="${LOGIN_HOST:-kraken}"        # nodo de login por el que pasa el túnel
NODE="$(hostname)"

echo "[$(date)] Nodo: $NODE   Puerto: $PORT   Config: $MODEL_CFG"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true

# --- Model server en background ----------------------------------------------
# Escucha en TODAS las interfaces (0.0.0.0) para que el nodo de login pueda
# alcanzarlo cuando arme el túnel hacia esta máquina.
echo "[$(date)] Iniciando model server en 0.0.0.0:$PORT"
uv run vla-eval serve -c "$MODEL_CFG" --address "0.0.0.0:$PORT" -v &
SERVER_PID=$!

# Detener el server al terminar (éxito, error o timeout del job).
cleanup() {
  echo "[$(date)] Deteniendo model server (pid $SERVER_PID)"
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Esperar a que el server esté listo --------------------------------------
# Hasta ~15 min, porque la 1ª vez descarga el checkpoint desde HuggingFace.
echo "[$(date)] Esperando a que el server responda en http://localhost:$PORT/health ..."
for i in $(seq 1 180); do
  if curl -s --max-time 2 "http://localhost:$PORT/health" >/dev/null; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[$(date)] ERROR: el model server murió durante el arranque."
    exit 1
  fi
  if [ "$i" -eq 180 ]; then
    echo "[$(date)] ERROR: timeout esperando al model server."
    exit 1
  fi
  sleep 5
done

cat <<EOF

==================================================================
 MODEL SERVER LISTO  ->  ${NODE}:${PORT}
 ------------------------------------------------------------------
 En la MÁQUINA DEL BENCHMARK (la que tiene Docker):

   1) Abre el túnel SSH:

        ssh -L localhost:${PORT}:${NODE}:${PORT} ${LOGIN_HOST}

   2) Corre el benchmark (desde el repo en esa máquina):

        PORT=${PORT} scripts/run_benchmark.sh

 Este job queda vivo sirviendo el modelo hasta que termine (--time)
 o lo canceles con:  scancel ${SLURM_JOB_ID:-<jobid>}
==================================================================

EOF

# Mantener el job vivo mientras el server atiende peticiones.
wait "$SERVER_PID"
