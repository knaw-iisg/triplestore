#!/usr/bin/env python3
"""Merge a nightly-harvest run's pipeline summary with a post-reindex snapshot
of per-graph triple counts and the authority-interlinking count, then append
the result as one line to run-history.jsonl.

Split out of nightly-harvest.sh (rather than inlined as a shell heredoc) so
the SPARQL JSON results never have to round-trip through shell quoting.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary-json", type=Path, required=True,
                         help="run_pipelines.py's --summary-json output")
    parser.add_argument("--graph-counts-json", type=Path, required=True,
                         help="raw SPARQL JSON results for the per-graph COUNT(*) query")
    parser.add_argument("--subject-counts-json", type=Path, required=True,
                         help="raw SPARQL JSON results for the per-graph COUNT(DISTINCT ?s) query")
    parser.add_argument("--predicate-counts-json", type=Path, required=True,
                         help="raw SPARQL JSON results for the per-graph COUNT(DISTINCT ?p) query")
    parser.add_argument("--object-counts-json", type=Path, required=True,
                         help="raw SPARQL JSON results for the per-graph COUNT(DISTINCT ?o) query")
    parser.add_argument("--interlink-json", type=Path, required=True,
                         help="raw SPARQL JSON results for the authority-interlink COUNT query")
    parser.add_argument("--pipelines-exit", type=int, required=True)
    parser.add_argument("--history-file", type=Path, required=True)
    args = parser.parse_args()

    summary = json.loads(args.summary_json.read_text())
    summary["pipelines_exit"] = args.pipelines_exit

    def parse_per_graph_counts(path, what):
        try:
            rows = json.loads(path.read_text())["results"]["bindings"]
            return {r["g"]["value"]: int(r["c"]["value"]) for r in rows}
        except Exception as e:
            print(f"WARN: couldn't parse {what}: {e}")
            return {}

    summary["graph_counts"] = parse_per_graph_counts(args.graph_counts_json, "graph counts")
    summary["graph_subject_counts"] = parse_per_graph_counts(args.subject_counts_json, "graph subject counts")
    summary["graph_predicate_counts"] = parse_per_graph_counts(args.predicate_counts_json, "graph predicate counts")
    summary["graph_object_counts"] = parse_per_graph_counts(args.object_counts_json, "graph object counts")

    try:
        row = json.loads(args.interlink_json.read_text())["results"]["bindings"][0]
        summary["interlinked_authority_iris"] = int(row["n"]["value"])
    except Exception as e:
        print(f"WARN: couldn't parse interlink count: {e}")

    with args.history_file.open("a") as f:
        f.write(json.dumps(summary) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
