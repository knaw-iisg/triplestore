#!/usr/bin/env bash
# Nightly: pull the latest of all 8 ETL pipelines + the orchestrator, run
# them, drop the output straight into this repo's sources/, re-index QLever,
# and restart it. Runs as the `silk` user via nightly-harvest.timer.
#
# Individual pipeline failures don't stop the others (run_pipelines.py's own
# behavior) -- a bad day for one source shouldn't block re-indexing what did
# work. Everything is appended to nightly-harvest.log for after-the-fact
# debugging.
set -uo pipefail

PIPELINES_ROOT="$HOME/pipelines"
TRIPLESTORE="$HOME/triplestore"
LOG="$TRIPLESTORE/nightly-harvest.log"
PIPELINE_REPOS="biblio-etl archive-etl findingaid-etl authorities-etl events-etl orcid-etl dataverse-etl identity-etl iisg-kg-etl"

{
  echo "=== nightly harvest started $(date -Is) ==="

  echo "--- pulling latest pipeline code ---"
  for repo in $PIPELINE_REPOS; do
    if ! (cd "$PIPELINES_ROOT/$repo" && git pull --ff-only -q); then
      echo "WARN: git pull failed for $repo, running with whatever's already checked out"
    fi
  done

  echo "--- refreshing dependencies ---"
  for repo in biblio-etl archive-etl findingaid-etl authorities-etl events-etl orcid-etl identity-etl; do
    "$PIPELINES_ROOT/$repo/.venv/bin/pip" install -q -e "$PIPELINES_ROOT/$repo[test]"
  done
  "$PIPELINES_ROOT/dataverse-etl/.venv/bin/pip" install -q -r "$PIPELINES_ROOT/dataverse-etl/requirements.txt"

  echo "--- running all 8 pipelines ---"
  python3 "$PIPELINES_ROOT/iisg-kg-etl/run_pipelines.py" \
    --pipelines-root "$PIPELINES_ROOT" \
    --output-dir "$TRIPLESTORE/sources"
  PIPELINES_STATUS=$?

  echo "--- re-indexing QLever (~1 min) ---"
  export PATH="$HOME/.venvs/qlever/bin:$PATH"
  cd "$TRIPLESTORE"
  qlever index --overwrite-existing
  qlever stop
  qlever start

  echo "=== nightly harvest finished $(date -Is), pipelines exit=$PIPELINES_STATUS ==="
  echo
} >> "$LOG" 2>&1
