# triplestore

A [QLever](https://github.com/ad-freiburg/qlever) SPARQL store loading the
output of all six IISG ETL pipelines, each into its own named graph, to
verify (and let you query) how they interlink:

| Graph | From |
|---|---|
| `https://iisg.amsterdam/graph/biblio` | [biblio-etl](https://github.com/knaw-iisg/biblio-etl) |
| `https://iisg.amsterdam/graph/archive` | [archive-etl](https://github.com/knaw-iisg/archive-etl) |
| `https://iisg.amsterdam/graph/findingaid` | [findingaid-etl](https://github.com/knaw-iisg/findingaid-etl) |
| `https://iisg.amsterdam/graph/authority` | [authorities-etl](https://github.com/knaw-iisg/authorities-etl) |
| `https://iisg.amsterdam/graph/dataverse` | [dataverse-etl](https://github.com/knaw-iisg/dataverse-etl) |
| `https://iisg.amsterdam/graph/orcid` | [orcid-etl](https://github.com/knaw-iisg/orcid-etl) |

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

`orcid-etl` is the one exception: its output is personally-identifying (real
colleagues' employment/works/funding data) and deliberately never lives
inside that repo at all -- generate it straight into place instead of
hardlinking:

```bash
cd ../orcid-etl && python3 -m orcid_etl.cli --out ../triplestore/sources/orcid.ttl
```

Then, with Docker and the `qlever` CLI (`pip install -r requirements.txt`):

```bash
qlever index   # ~1 minute for the full ~24.5M-triple corpus
qlever start   # serves on http://localhost:7878 (see [server] PORT in Qleverfile)
qlever stop
```

## Querying

```bash
curl http://localhost:7878 --data-urlencode "query=$(cat queries/graph_counts.rq)" -H "Accept: text/csv"
```

Or `qlever ui` for an interactive, autocompleting query editor at
http://localhost:7876/default -- its config (`Qleverfile-ui.yml`, tracked
in git like `Qleverfile`) points `baseUrl` at `http://localhost:7878`
deliberately: that value is read by the UI's own browser-side JavaScript,
not resolved inside a container, so it needs to be reachable from whatever
machine's browser is looking at the page -- `localhost` is the portable
choice for "the same machine that's running the containers", which is the
only setup this repo assumes. (An earlier version of this file had the
*indexing* machine's own hostname baked in instead, which happened to
still resolve for its author via their own `/etc/hosts` but breaks for
anyone else -- verified by loading the page in a real browser and running
a query end-to-end before fixing it.)

## Tweaking settings

Everything's in `Qleverfile` -- port, memory limits, cache size, which files
load into which graph. Re-run `qlever index` after changing `[index]`
settings, or just `qlever stop && qlever start` for `[server]` settings.

## Interlink verification results (2026-09-28 full harvest, post-fix)

Graph sizes: biblio 18,353,945 · findingaid 4,483,744 · authority 2,506,569 ·
dataverse 306,293 · archive 146,603 (25.8M unique triples total).

- **588,435** distinct `person:`/`organization:`/`place:`/`topic:`/`period:`/
  `form:`/`title:`/`event:` IRIs have data in *both* the `authority` graph
  and at least one of biblio/archive/findingaid's graphs -- confirming
  authorities-etl actually populates the names/`sameAs` that the other three
  pipelines mint but leave bare (`queries/interlink_check.rq`).
- **5,536** `collection:<id>` IRIs have data in *both* archive-etl's graph
  and findingaid-etl's graph (`queries/collection_interlink_check.rq`) --
  archive-etl's flat MARC record and findingaid-etl's full EAD component
  hierarchy for the same archive, deliberately sharing one IRI. Spot-checked
  on `collection:ARCH00018` (30 triples from archive-etl, 46 from
  findingaid-etl, same subject).

## A real bug this setup caught

Loading the *actual full-harvest output* (not just small fixture samples)
surfaced a bug neither biblio-etl's nor archive-etl's own test suites
caught: `GRAPH ?g { ?s a ?type }` on the archive graph returned only one
result (`dataset:archive a sdo:Dataset`) -- every archive record was
missing its own `rdf:type` entirely (and the collection-interlink count
above was 0, not 5,536, until this was fixed -- that query specifically
needs both graphs' `rdf:type`, so it's a clean before/after signal). Root
cause and fix: see biblio-etl/archive-etl commit history (`text_content()`
in `context.py`) -- MARC's `<leader>` element has no XML attributes, so it
collapses to a plain string via `xmltodict` rather than `{"$text": ...}`,
and both repos' *own test fixtures* (inherited pre-converted, not produced
by their own `harvest.py`) happened to always use the dict shape, masking
it. Lesson: fixture-only testing can't catch a fixture that doesn't match
what the real pipeline actually produces -- querying the real, merged,
full-scale output is what caught it. Both repos were re-harvested in full
after the fix; the numbers above are post-fix.
