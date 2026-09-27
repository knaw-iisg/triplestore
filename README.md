# triplestore

A [QLever](https://github.com/ad-freiburg/qlever) SPARQL store loading the
output of all five IISG ETL pipelines, each into its own named graph, to
verify (and let you query) how they interlink:

| Graph | From |
|---|---|
| `https://iisg.amsterdam/graph/biblio` | [biblio-etl](https://github.com/knaw-iisg/biblio-etl) |
| `https://iisg.amsterdam/graph/archive` | [archive-etl](https://github.com/knaw-iisg/archive-etl) |
| `https://iisg.amsterdam/graph/findingaid` | [findingaid-etl](https://github.com/knaw-iisg/findingaid-etl) |
| `https://iisg.amsterdam/graph/authority` | [authorities-etl](https://github.com/knaw-iisg/authorities-etl) |
| `https://iisg.amsterdam/graph/dataverse` | [dataverse-etl](https://github.com/knaw-iisg/dataverse-etl) |

**Why named graphs, not one merged graph:** keeps provenance (which pipeline
asserted what) while still letting any query union across them with
`GRAPH ?g { ... }` or by naming specific graphs. See `queries/` for examples,
including the actual interlink verification queries run during development.

## Setup

This repo holds only the **settings** (`Qleverfile`) and **tracked queries**
(`queries/`) -- not the ~3GB of source data or the built index, both
gitignored. `sources/` needs to be populated with hardlinks (same filesystem,
so this costs no extra disk) to each pipeline repo's own `derived/` output
before indexing:

```bash
mkdir -p sources
ln ../biblio-etl/derived/biblio.nt sources/biblio.nt
ln ../archive-etl/derived/archive.nt sources/archive.nt
ln ../findingaid-etl/derived/findingaid.nt sources/findingaid.nt
ln ../authorities-etl/derived/authorities.nt sources/authorities.nt
ln ../dataverse-etl/data/derived/knaw-huc/knaw-huc-dataverse.ttl sources/dataverse.ttl
```

Then, with the `qlever` CLI (`pip install qlever`) and Docker:

```bash
qlever index   # ~1 minute for the full ~24.5M-triple corpus
qlever start   # serves on http://localhost:7878 (see [server] PORT in Qleverfile)
qlever stop
```

## Querying

```bash
curl http://localhost:7878 --data-urlencode "query=$(cat queries/graph_counts.rq)" -H "Accept: text/csv"
```

Or use the QLever UI (`qlever ui`) for an interactive query editor.

## Tweaking settings

Everything's in `Qleverfile` -- port, memory limits, cache size, which files
load into which graph. Re-run `qlever index` after changing `[index]`
settings, or just `qlever stop && qlever start` for `[server]` settings.

## Interlink verification results (2026-09-27/28 full harvest)

- **588,184** distinct `person:`/`organization:`/`place:`/`topic:`/`period:`/
  `form:`/`title:`/`event:` IRIs have data in *both* the `authority` graph
  and at least one of biblio/archive/findingaid's graphs -- confirming
  authorities-etl actually populates the names/`sameAs` that the other three
  pipelines mint but leave bare (`queries/interlink_check.rq`).
- archive-etl and findingaid-etl deliberately mint the same `collection:<id>`
  IRI for a given archive's flat MARC record vs. its full EAD component
  hierarchy; spot-checked on `collection:ARCH00018` (30 triples from
  archive-etl, 46 from findingaid-etl, same subject) via
  `queries/collection_interlink_check.rq`.

## A real bug this setup caught

Loading the *actual full-harvest output* (not just small fixture samples)
surfaced a bug neither biblio-etl's nor archive-etl's own test suites
caught: `GRAPH ?g { ?s a ?type }` on the archive graph returned only one
result (`dataset:archive a sdo:Dataset`) -- every archive record was
missing its own `rdf:type` entirely. Root cause and fix: see those repos'
`context.py`/`pipeline.py` commit history (`text_content()`). Left as a
lesson here too: fixture-only testing can't catch a fixture that doesn't
match what the real pipeline actually produces -- querying the real,
merged, full-scale output is what caught it.
