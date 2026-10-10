#!/usr/bin/env bash
# Nightly: pull the latest of all 8 ETL pipelines + the orchestrator, run
# them, drop the output straight into this repo's sources/, re-index QLever,
# and restart it. Runs as the `silk` user via nightly-harvest.timer.
#
# Individual pipeline failures don't stop the others (run_pipelines.py's own
# behavior) -- a bad day for one source shouldn't block re-indexing what did
# work. Everything is appended to nightly-harvest.log for after-the-fact
# debugging, and a structured one-line-per-run summary (timing, per-pipeline
# status, resulting per-graph triple counts) is appended to run-history.jsonl
# for iisg-kb-viewer's "Data science" / "Growth" views to read. That file is
# chmod'd world-readable since it's read by the `kbviewer` system user, not
# `silk`.
set -uo pipefail

PIPELINES_ROOT="$HOME/pipelines"
TRIPLESTORE="$HOME/triplestore"
LOG="$TRIPLESTORE/nightly-harvest.log"
RUN_HISTORY="$TRIPLESTORE/run-history.jsonl"
SPARQL_ENDPOINT="http://localhost:7878"
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
  SUMMARY_JSON="$TRIPLESTORE/run-summary.tmp.json"
  python3 "$PIPELINES_ROOT/iisg-kg-etl/run_pipelines.py" \
    --pipelines-root "$PIPELINES_ROOT" \
    --output-dir "$TRIPLESTORE/sources" \
    --summary-json "$SUMMARY_JSON"
  PIPELINES_STATUS=$?

  echo "--- re-indexing QLever (~1 min) ---"
  export PATH="$HOME/.venvs/qlever/bin:$PATH"
  cd "$TRIPLESTORE"
  qlever index --overwrite-existing
  qlever stop
  qlever start

  echo "--- recording run history snapshot ---"
  # Give the freshly restarted container a moment to come up before querying it.
  sleep 5
  GRAPH_COUNTS_TMP="$TRIPLESTORE/graph-counts.tmp.json"
  SUBJECT_COUNTS_TMP="$TRIPLESTORE/subject-counts.tmp.json"
  PREDICATE_COUNTS_TMP="$TRIPLESTORE/predicate-counts.tmp.json"
  OBJECT_COUNTS_TMP="$TRIPLESTORE/object-counts.tmp.json"
  INTERLINK_TMP="$TRIPLESTORE/interlink.tmp.json"
  curl -s "$SPARQL_ENDPOINT" \
    --data-urlencode "query=SELECT ?g (COUNT(*) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g" \
    -H "Accept: application/sparql-results+json" -o "$GRAPH_COUNTS_TMP"
  # Distinct subjects/predicates are a more substantive growth signal than
  # raw triple count -- subjects track actual new entities (new books, new
  # people) rather than the same records just picking up more properties;
  # predicates track how varied the schema usage is, which should mostly
  # stay flat day-to-day and only jump when a pipeline starts asserting a
  # genuinely new field.
  curl -s "$SPARQL_ENDPOINT" \
    --data-urlencode "query=SELECT ?g (COUNT(DISTINCT ?s) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g" \
    -H "Accept: application/sparql-results+json" -o "$SUBJECT_COUNTS_TMP"
  curl -s "$SPARQL_ENDPOINT" \
    --data-urlencode "query=SELECT ?g (COUNT(DISTINCT ?p) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g" \
    -H "Accept: application/sparql-results+json" -o "$PREDICATE_COUNTS_TMP"
  # Distinct objects (literals and IRIs both) isn't tracked as its own
  # "Growth" tab -- it's dominated by literal diversity (free-text titles,
  # dates, ...) and isn't a meaningful trend on its own. It's recorded
  # purely so the Growth view can show a S/P/O composition breakdown
  # (counts + % of that graph's own triple count) on hover, alongside the
  # subject/predicate counts above.
  curl -s "$SPARQL_ENDPOINT" \
    --data-urlencode "query=SELECT ?g (COUNT(DISTINCT ?o) AS ?c) WHERE { GRAPH ?g { ?s ?p ?o } } GROUP BY ?g" \
    -H "Accept: application/sparql-results+json" -o "$OBJECT_COUNTS_TMP"
  curl -s "$SPARQL_ENDPOINT" \
    --data-urlencode "query=PREFIX sdo: <https://schema.org/> SELECT (COUNT(DISTINCT ?iri) AS ?n) WHERE { GRAPH <https://iisg.amsterdam/graph/authority> { ?iri a ?t } GRAPH ?og { ?iri ?p ?o } FILTER(?og != <https://iisg.amsterdam/graph/authority>) }" \
    -H "Accept: application/sparql-results+json" -o "$INTERLINK_TMP"
  python3 "$TRIPLESTORE/deploy/record_run_history.py" \
    --summary-json "$SUMMARY_JSON" \
    --graph-counts-json "$GRAPH_COUNTS_TMP" \
    --subject-counts-json "$SUBJECT_COUNTS_TMP" \
    --predicate-counts-json "$PREDICATE_COUNTS_TMP" \
    --object-counts-json "$OBJECT_COUNTS_TMP" \
    --interlink-json "$INTERLINK_TMP" \
    --pipelines-exit "$PIPELINES_STATUS" \
    --history-file "$RUN_HISTORY"
  chmod 644 "$RUN_HISTORY"
  rm -f "$SUMMARY_JSON" "$GRAPH_COUNTS_TMP" "$SUBJECT_COUNTS_TMP" "$PREDICATE_COUNTS_TMP" "$OBJECT_COUNTS_TMP" "$INTERLINK_TMP"

  echo "=== nightly harvest finished $(date -Is), pipelines exit=$PIPELINES_STATUS ==="
  echo
} >> "$LOG" 2>&1
