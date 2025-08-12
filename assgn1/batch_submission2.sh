#!/usr/bin/env bash
#SBATCH --job-name=compute_pi_exp
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --time=01:00:00
#SBATCH --output=compute_pi_%j.out
#SBATCH --error=compute_pi_%j.err
# Adjust above SBATCH lines to match your cluster policies (walltime, cpus, nodes, etc.)

# -------------------------
# User-editable parameters
# -------------------------
SRC="compute_pi.c"          # source file
BIN="./compute_pi"          # binary name
N=10000000                  # number of iterations (matches the assignment)
THREADS_LIST=(1 2 4 8 16)   # powers of two up to 16
CHUNK_SIZES=(10 100 1000)
RESULT_DIR="results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULT_DIR}"

# Save environment info for reproducibility
echo "Job: ${SLURM_JOB_ID:-local}" > "${RESULT_DIR}/env_info.txt"
echo "Host: $(hostname)" >> "${RESULT_DIR}/env_info.txt"
echo "Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "${RESULT_DIR}/env_info.txt"
echo "Cores allocated (SLURM_CPUS_ON_NODE): ${SLURM_CPUS_ON_NODE:-${SLURM_CPUS_PER_TASK:-16}}" >> "${RESULT_DIR}/env_info.txt"

# -------------------------
# Build
# -------------------------
echo "Compiling ${SRC} with -fopenmp..."
gcc -O2 -fopenmp "${SRC}" -o "${BIN}" || { echo "Build failed"; exit 1; }
echo "Build OK." >> "${RESULT_DIR}/env_info.txt"

# helper to measure wall time with nanosecond precision
measure_and_run() {
  local label="$1"
  shift
  local out_csv="$1"
  shift

  # record start (float seconds)
  local start=$(date +%s.%N)
  # run the actual command
  "$@"
  local status=$?
  local end=$(date +%s.%N)
  # compute elapsed using awk for floating math
  local elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN{ printf "%.6f", e - s }')
  # append result: timestamp,label,cmd,elapsed,exit
  printf '%s,%s,"%s",%s,%d\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$label" "$*" "$elapsed" "$status" >> "${out_csv}"
  return $status
}

# -------------------------
# (a) Thread placement experiments
#    Compare OMP_PLACES = cores|sockets and OMP_PROC_BIND = close|spread
# -------------------------
placement_csv="${RESULT_DIR}/placement_experiments.csv"
echo "timestamp,placement_bind,command,elapsed_sec,exitcode" > "${placement_csv}"
PLACES=("cores" "sockets")
BIND=("close" "spread")

for place in "${PLACES[@]}"; do
  for bind in "${BIND[@]}"; do
    export OMP_PLACES="${place}"
    export OMP_PROC_BIND="${bind}"
    # run with a representative thread count (use max cpus-per-task)
    export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-16}
    label="places=${OMP_PLACES};bind=${OMP_PROC_BIND};threads=${OMP_NUM_THREADS}"
    echo "Running placement test: ${label}"
    measure_and_run "${label}" "${placement_csv}" "${BIN}" "${N}"
  done
done

# -------------------------
# (b) Varying number of threads (powers of two up to 16)
# -------------------------
threads_csv="${RESULT_DIR}/threads_scaling.csv"
echo "timestamp,threads,placement_bind,command,elapsed_sec,exitcode" > "${threads_csv}"

# keep a stable placement/bind for these tests (you may change these)
export OMP_PLACES="cores"
export OMP_PROC_BIND="close"

for t in "${THREADS_LIST[@]}"; do
  export OMP_NUM_THREADS="${t}"
  label="threads=${t};places=${OMP_PLACES};bind=${OMP_PROC_BIND}"
  echo "Running threads test: ${label}"
  measure_and_run "${label}" "${threads_csv}" "${BIN}" "${N}"
done

# -------------------------
# (c) For threads=16 compare static/dynamic schedules and chunk sizes
# -------------------------
sched_csv="${RESULT_DIR}/scheduling.csv"
echo "timestamp,schedule,chunk,threads,placement_bind,command,elapsed_sec,exitcode" > "${sched_csv}"

export OMP_NUM_THREADS=16
export OMP_PLACES="cores"
export OMP_PROC_BIND="close"

SCHEDULES=("static" "dynamic")

for sched in "${SCHEDULES[@]}"; do
  for chunk in "${CHUNK_SIZES[@]}"; do
    # set schedule, e.g. "static,100"
    export OMP_SCHEDULE="${sched},${chunk}"
    label="schedule=${OMP_SCHEDULE};threads=${OMP_NUM_THREADS}"
    echo "Running schedule test: ${label}"
    measure_and_run "${label}" "${sched_csv}" "${BIN}" "${N}"
  done
done

echo "All experiments finished. Results directory: ${RESULT_DIR}"
echo "Files:"
ls -lh "${RESULT_DIR}"
