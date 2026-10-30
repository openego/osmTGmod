# Status — grid district / osmTGmod reproducibility

**Date:** 2026-10-30 · **Scope:** eGon-data #804, #769 · osmTGmod #19 · eGon-data PR #1506

---

# TL;DR (for humans)

## Where things stand

Two **independent** bugs produced the same symptom, and both halves had to be fixed.

**eGon-data — essentially done, waiting on review.** The grid-district algorithm was
non-deterministic given fixed input. Fixed and verified; **PR #1506** has been open since
2 September with zero reviews. One gap remains: `substation_voronoi.py` sits in the
middle of the chain, carries three order-dependencies of exactly the class that was fixed
everywhere else, and was never touched. It has not been observed to fire, so treat it as
latent rather than live (§2.1).

**osmTGmod — fixed, nearly verified, not yet proposed.** The analysis is finished and a
working fix exists: 23 changes taking Schleswig-Holstein from 9 different results in 10
runs to **20 of 20 byte-identical**. Full Germany is green except for one last defect,
which is **fixed but has never been exercised by a run**. The work is committed and
pushed as `fixes/#19-grid-reproducibility` (`81108d6`), but there is **no PR**, and issue
#19 documents only the analysis — it does not mention that the branch exists. So anyone
starting from #19 would reasonably think the fixing still has to be done. It doesn't;
it needs verifying and proposing.

**Until the osmTGmod half ships, full pipeline runs will keep producing different
grids** — the eGon-data fix alone cannot stabilise its own input.

## Do these next, in order

1. **Verify the last fix** (~2.9 h of machine time, unattended) — see §5.1. It is the
   only change on the branch that has never been exercised by a run.
2. **Open the osmTGmod PR** from `fixes/#19-grid-reproducibility` against `features/egon`, and link it from
   issue #19 — which currently gives no hint that a fix exists.
3. **Get PR #1506 reviewed.** It has sat open with zero reviews for ~8 weeks.

## One finding worth reading even if you read nothing else

One of the defects on the branch is a **correctness** bug, not merely a reproducibility
one: it can leave branches referencing a bus that has been deleted, within a single run.
That is the strongest argument for merging, and §4.3 gives a one-query check for it.

---

# 1. The problem

eGon-data produces a different grid on every run from identical OSM input:

- **openego/eGon-data#769** — the number of HV/MV substations differs between runs
  (observed: 200 / 201 / 201 / 202 over four full runs).
- **openego/eGon-data#804** — MV grid district geometries differ between runs.

These turned out to be **two independent defects** that produce the same symptom:

| # | layer | status |
|---|---|---|
| 1 | eGon-data's grid district algorithm is non-deterministic *given fixed input* | fixed + verified, PR #1506 open |
| 2 | osmTGmod's abstraction is non-deterministic, so the *input itself* moves | fixed on `fixes/#19-grid-reproducibility`, mostly verified, **no PR yet** |

Neither fix alone makes a full pipeline run reproducible.

---

# 2. Where each half stands, in detail

## 2.1 eGon-data — PR #1506

**What it contains** (5 commits, 6 files, targeting `dev`):

```
422d23d3b  Fix MV grid districts differing between runs
79dab6515  Bump version of MvGridDistricts to 0.0.6
c466371c2  Update changelog
8484bf77a  Order the area sums in MV grid districts
c7c1dc47c  Make osmTGmod's input reproducible #769
```

```
CHANGELOG.rst                                   +39/-0
src/egon/data/datasets/mv_grid_districts.py     +73/-39
src/egon/data/datasets/osmtgmod/__init__.py     +12/-3
src/egon/data/datasets/substation/__init__.py   +34/-2
src/egon/data/datasets/substation/ehv_substation.sql   +5/-1
src/egon/data/datasets/substation/hvmv_substation.sql  +5/-1
```

**Verified.** `define_mv_grid_districts()` re-run ten times with different query plans
forced, against two independent databases: **3 differing results out of 10 before the
fix, all 10 identical after.** Separately, five full pipeline runs (each preceded by a
dataset-version reset): four produced the same substation set, and for those four
`grid.egon_hvmv_substation`, `grid.egon_hvmv_substation_voronoi` and
`grid.egon_mv_grid_district` came back **byte-identical in all six pairwise
comparisons**.

**The remaining gap — `substation_voronoi.py` was never fixed.** It is not in the PR
diff, is still at version `0.0.3`, and contains three order-dependencies of the same
class as everything else that was fixed:

```sql
-- 1. feeds ST_VoronoiPolygons from an unordered collection
SELECT (ST_Dump(ST_VoronoiPolygons(ST_collect(a.point)))).geom FROM <substations> a;

-- 2. `id` is a serial, so cell ids follow scan order
INSERT INTO <voronoi> (geom) (SELECT ... FROM <boundaries> a CROSS JOIN <view> b);

-- 3. UPDATE ... FROM with a GROUP BY that can yield several rows per voi.id
--    -> PostgreSQL uses one of them, unpredictably
UPDATE <voronoi> t1 SET bus_id = t2.bus_id
  FROM (SELECT voi.id, sub.bus_id FROM <voronoi> voi, <substations> sub
        WHERE ST_CONTAINS(voi.geom, sub.point) GROUP BY voi.id, sub.bus_id) t2
 WHERE t1.id = t2.id;
```

(3) fires when a voronoi cell contains two substations — which happens when two
substations share coordinates, since `ST_VoronoiPolygons` collapses coincident points
into one cell. Not observed in any run so far (the voronoi table was byte-identical
whenever the substation set was), so treat it as **latent**. (1) is probably harmless
because GEOS sorts its input sites internally, but that was never verified empirically.

**Also true:** #1506 alone does not make full runs reproducible, and the PR description
says so.

## 2.2 osmTGmod — issue #19

**Analysis: complete.** Seven classes of root cause, every site located, documented in
openego/osmTGmod#19 (opened 2 Sep).

**Fix: exists and largely verified, but not yet proposed.**

- Branch `fixes/#19-grid-reproducibility`, commit `81108d6` "Add orderings for reprocucibility",
  pushed to `origin` (openego/osmTGmod)
- 23 changes, +198/-25 across `sql-scripts/functions.sql` and `power_script.sql`
- **No pull request yet**, and issue #19 does **not** mention that the branch exists

**Verification status:**

| extent | trials | result |
|---|---|---|
| Schleswig-Holstein, before any fix | 10 | **9 distinct** results; bus counts 680/681/682 |
| Schleswig-Holstein, after fixes | **20** | **all identical** |
| Schleswig-Holstein, after the three `LIMIT 1` fixes | 10 | all identical (687 buses) |
| Full Germany | 2 | identical **except** `branch_id` assignment |
| Full Germany, after the final fix | **0** | **never run** |

---

# 3. What was done

## 3.1 Method

The breakthrough was realising `power_script.sql` is **idempotent**: it writes nothing to
`power_ways` / `power_relations` / `power_way_nodes` (only `otg_create_power_tables()`
does, at import time) and drops and rebuilds every table it owns on entry. So it can be
re-executed repeatedly against one prepared database — **~100 s per trial on SH, ~78 min
on full DE**, instead of a multi-hour pipeline run.

Two harnesses were built on that:

- **`otg_trials.sh`** — runs the unmodified script N times, fingerprints the final
  `bus_data`/`branch_data`. **This is the only thing that certifies determinism.**
- **`otg_bisect.sh`** — runs an instrumented copy with a probe after each of the 44
  `otg_*()` calls, and reports the first step at which trials disagree. **Localisation
  only** — see the trap in §7.2.

The fix loop was then: run → find first divergence → read that function → add a
deterministic order → repeat. The first divergence walked 8 → 25 → 28 → 32 → 33 → back
to 4 → 24 → 35 → branch renumbering → green, over eleven rounds. Each fix exposed one it
had been masking, which is why it took eleven and not three.

## 3.2 The osmTGmod fixes, by class

| class | sites |
|---|---|
| cursor loops whose body mutates what they read | `otg_get_all_neighbours` (×2), the three cable/frequency heuristics, `otg_create_grid_topology`, `otg_seperate_voltage_levels`, `otg_substract_cables_within_buffer`, `otg_connect_busses_to_lines_1`/`_2`, `otg_transfer_busses`, `otg_connect_transformers`, `otg_connect_subgrids`, `otg_simplify_branches`, `otg_drop_buffers_matching_busses`, `otg_calc_max_node_power` |
| serial ids handed out in scan order | both `branch_data` inserts; `pgr_createTopology`'s input via `branch_data_topo` |
| arbitrary single-row picks (`LIMIT 1`, `DISTINCT ON`, `UPDATE…FROM`) | DFS root in `otg_connect_subgrids`; `DISTINCT ON` in `otg_connect_substation_vertices`; three `LIMIT 1`s |
| tie-breaks decided by scan order (strict `<`) | `otg_transfer_busses`, `otg_connect_subgrids` |
| order-dependent float sums over `real` | `sum(s_long)`, `sum(pmax)`, `sum(s_long_sum)` |

Two needed more than an `ORDER BY`:

- `PERFORM f(id) FROM t` had to become an explicit ordered loop, because **a target list
  is evaluated before the sort** — adding `ORDER BY` to such a `SELECT` does nothing.
- One of those could not be a `DO $$ … $$` block, because eGon-data executes
  `power_script.sql` by splitting it on every semicolon outside single quotes and would
  tear a dollar-quoted body apart. Hence a new named function,
  `otg_substract_cables_within_buffer_all()`.

---

# 4. Findings

## 4.1 The underlying shape

osmTGmod's abstraction is an in-place graph rewrite: ~40 sequential `otg_*()` calls whose
bodies loop over rows and mutate the very tables they are reading. **41 of 43 cursor
loops had no `ORDER BY`.** PostgreSQL does not define row order without one, so the
output became a function of whatever order the scan happened to return.

`pgr_createTopology` (pgRouting 3.8.0) deserves a special mention: it walks the edge
table with no `ORDER BY` and `_pgr_pointToId` both allocates vertex ids from a
`bigserial` *and* decides whether a point is new using a tolerance. So visitation order
determines the numbering **and which endpoints get merged** — the vertex set itself. The
source already carries the comment `-- pgr_createTopology should not be used.` The fix
was to order its input table; its `rows_where` parameter cannot carry an `ORDER BY`
because it is wrapped as `' AND ('||rows_where||')'`.

## 4.2 Scale matters — SH systematically under-tests

| ambiguity | SH | full DE |
|---|---|---|
| overlapping NUTS-0 polygons | 0 | 0 |
| overlapping substation polygons | 1 | 12 |
| buses inside **two** substation polygons | **0** | **35** |
| buses with ≥2 substations in the 400 m buffer | 136 / 487 | **2,289 / 10,910** (up to 6) |
| `power_line_sep` rows sharing a `line_id` | 2 line_ids | 107 line_ids |
| max lines meeting at one endpoint | — | 8 |

Two fixes are live at national scale but had **zero** exercise in SH. Conversely the
10-slot cap in `v_all_neighbours` is provably safe: max endpoint degree is 8.

## 4.3 This is a correctness bug, not just a reproducibility bug

`otg_drop_buffers_matching_busses` merges buses within a 10 m buffer. In the **original**
code the survivor and the victims are chosen by **two independent evaluations of a
non-total sort**:

```sql
SET t_bus = (SELECT id FROM bus_data WHERE … ORDER BY substation_id LIMIT 1)    -- survivor
SET f_bus = (SELECT id FROM bus_data WHERE … ORDER BY substation_id LIMIT 1)    -- survivor
DELETE FROM bus_data WHERE id IN (SELECT id … ORDER BY substation_id OFFSET 1)  -- victims
```

Many buses share a `substation_id`, and it can be NULL. When the `LIMIT 1` and the
`OFFSET 1` resolve the tie differently, **the bus the branches were repointed at is not
the bus that survived** — leaving branches referencing a deleted bus.

Such a branch has no resolvable endpoint, so the later branch-specification step cannot
compute its reactance and leaves `br_x` NULL — which is the signature to look for. The
branch fixes this by adding `, id` to all three clauses, making both selections agree.

**Confidence:** the mechanism is certain from reading the code; what has not been
demonstrated end-to-end is that it is the cause of any particular observed case. A direct
check on any result database:

```sql
SELECT branch_id, f_bus, t_bus FROM branch_data b
WHERE NOT EXISTS (SELECT 1 FROM bus_data WHERE id = b.f_bus)
   OR NOT EXISTS (SELECT 1 FROM bus_data WHERE id = b.t_bus);
```

Expect zero rows on a healthy run. This is the single most valuable thing to verify,
before and after the fix.

## 4.4 Incidental: duplicate branches

Full DE has **45 groups of fully duplicate rows in `branch_data`** (plus 34 in
`power_line_sep`, 13 in `power_circ_members`) — the same line represented twice. Not a
reproducibility problem and not addressed here, but it inflates the grid and looks like a
separate bug worth its own issue.

---

# 5. Next steps, prioritised

## 5.1 Verify the one unverified fix

The final fix — ordering both `branch_data` inserts by **every** selected column — was
applied after the last run and has never been exercised. Context: on full DE one
`power_line_sep` pair (`line_id = 24158393`) is identical in `line_id`, `voltage`,
`f_bus`, `t_bus`, `way`, `length`, `wires` and `frequency`, and differs **only in
`cables` (3 vs 9)**, so the previous four-column order was not total.

```bash
# from this directory, inside an osmTGmod checkout on the fix branch
PGPORT=<SH db>      ./scripts/otg_trials.sh 10 --yes   # ~12 min
PGPORT=<full DE db> ./scripts/otg_trials.sh 2  --yes   # ~2.6 h
```

Success = all six fingerprint columns show `1 distinct`. SH should give 687 buses; full
DE should give 14,980 buses / 28,136 branches.

## 5.2 Open the osmTGmod pull request

The work is committed and pushed (`fixes/#19-grid-reproducibility`, `81108d6`). What is missing is the PR
against `features/egon` and a link to it from issue #19.

The commit message is a one-liner, so the PR description is where the reasoning belongs —
§3.2 (the fix classes) and §4 (the findings) are written to be reusable for it. The
analysis already posted on #19 covers the problem statement.

**One decision is needed first.** All changes are pure tie-breaks except one:
`functions.sql:1199` (original numbering) also implements the existing TODO
*"verbessern: wenn Buffer mehrere findet soll er nähere nehmen"* — the **nearest**
substation instead of an arbitrary one. On full DE that affects 2,289 buses, so it is a
real modelling decision. Reverting it to `ORDER BY power_substation.id` keeps the branch
purely about reproducibility. Either is one line.

## 5.3 Get PR #1506 reviewed and merged

Open since 2 September with **zero reviews**. This is the blocker on the eGon-data half,
and there is active interest in having these fixes available.

## 5.4 Close the `substation_voronoi.py` gap

Three sites, §2.1. Requires bumping `substation_voronoi` to `0.0.4`. Small, and it
removes the last known order-dependency on the eGon-data side.

## 5.5 End-to-end confirmation

With both halves in place, three full pipeline runs, each preceded by
`reset_datasets.sh`, compared with `compare_runs.py`. The measure of success is
`otg_bus_data` coming back **identical**, which it has never done in any run so far.

## 5.6 Domain sanity check

Reproducible is not the same as correct. Fixing arbitrary choices necessarily settles
some differently: SH went 679–684 (wandering) → 687 (stable). Someone with the electrical
view should look at the resulting grid, not just at the determinism.

---

# 6. Material in this directory

This directory lives **inside the osmTGmod repository**, on branch
`fixes/#19-grid-reproducibility`. The harnesses therefore default to testing the checkout
they are sitting in: `OSMTGMOD_DIR` resolves to the repository root two levels up, and
run output is written to `results/` beside `scripts/` and `data/`.

Note the directory name begins with `#`, which a shell treats as a comment — quote it:
`cd '#19_grid_reproducibility_status'`.

## 6.1 The osmTGmod fix itself

Not in this directory — it lives in the repository, on branch `fixes/#19-grid-reproducibility`
(`81108d6`), pushed to openego/osmTGmod.

```bash
git fetch origin 'fixes/#19-grid-reproducibility'
git diff features/egon origin/'fixes/#19-grid-reproducibility' -- sql-scripts/
```

## 6.2 `scripts/`

| script | purpose | default port |
|---|---|---|
| `otg_trials.sh N [--yes]` | **ground truth.** Runs unmodified `power_script.sql` N times, fingerprints the result | 59734 |
| `otg_bisect.sh N` | localisation only. Instrumented copy, 44 probes, names the first diverging step | 59734 |
| `otg_cleanup.sql` | drops osmTGmod's transient tables; both harnesses call it before each trial | — |
| `reset_datasets.sh` | deletes the recorded rows for `Osmtgmod`, `substation_extraction`, `substation_voronoi`, `MvGridDistricts` from `metadata.datasets` so they actually re-execute | 59734 |
| `dump_run.sh <label>` | dumps the pipeline tables relevant to #804/#769 for one run | 59734 |
| `compare_runs.py a b` | diffs two `dump_run.sh` outputs, re-keyed on stable identifiers | — |
| `verify_804.py [--probe\|--cluster]` | eGon-data side: re-runs `define_mv_grid_districts()` under forced query plans; `--probe` counts tie-decided assignments read-only | 59734 |

All of them default to egon-data's documented connection settings
(`127.0.0.1:59734`, user `egon`, database `egon-data`, password `data`) and read the
standard `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE` environment
variables. **Always pass `PGPORT` explicitly** — a docker-compose instance rarely sits on
the default port, and pointing a run at the wrong database is the easiest way to waste
hours.

Both osmTGmod harnesses reload `functions.sql` from `OSMTGMOD_DIR` before trialling, so
an edit on disk is actually under test rather than whatever the database happens to hold.
`OSMTGMOD_DIR` defaults to the repository root above this directory; point it elsewhere
to trial a different checkout.

## 6.3 `data/` — the trial history

| file | date | extent | trials | buses | distinct `bus_full` | meaning |
|---|---|---|---|---|---|---|
| `trials.prev1.tsv` | 08-31 | SH | 10 | 680/681/682 | **9** | baseline, no fixes |
| `trials.prev2.tsv` | 08-31 | SH | 10 | 679–684 | 7 | after the first fix only |
| `trials.prev3.tsv` | 09-02 | SH | 10 | 683 | 2 | renumbering + one outlier |
| `trials.prev4.tsv` | 09-02 | SH | 10 | 683 | 1 | `branch_full` still 2 |
| `trials.prev5.tsv` | 09-02 | SH | **20** | 683 | **1** | **all green** |
| `trials.prev6.tsv` | 09-02 | SH | 10 | 687 | **1** | all green after the `LIMIT 1` fixes |
| `trials.tsv` | 09-03 | **full DE** | 2 | 14,980 | 1 | green except `branch_full` |

Columns: `trial, seconds, bus_rows, branch_rows, bus_full, bus_noid, branch_full,
branch_noid`. The `_noid` variants hash the table with the id column dropped, which
separates a pure renumbering from a genuine content change.

## 6.4 Material for the osmTGmod PR description

The commit on the branch carries only a one-line message, so the PR description is where
the reasoning should go. Reusable pieces, already written:

- **problem statement** — the analysis posted on openego/osmTGmod#19
- **what changed, by class** — §3.2
- **evidence** — §4.2 (the SH-vs-full-DE ambiguity table) and §6.3 (the trial history)
- **the correctness argument** — §4.3, the strongest reason to merge
- **caveats to declare** — the output changes (SH went 679–684 wandering → 687 stable),
  and the one semantic change at `:1199` (§5.2)

---

# 7. Traps — read before running anything

## 7.1 eGon-data skips datasets whose version is unchanged

`Dataset.check_version` skips every task when `metadata.datasets` already records the
same `(name, version, scenarios)`. Re-triggering the DAG against the same database does
**not** re-execute an unchanged dataset — its tables keep an earlier run's content while
everything around them is refreshed, producing a database whose tables were built at
different times.

**This invalidated eight full pipeline runs.** Comparisons made that way look stable and
prove nothing. Always run `reset_datasets.sh` before each comparison run, and check the
`dataset_versions` dump afterwards to confirm the datasets really executed.

## 7.2 The bisect harness masks the thing it is measuring

Shown twice: `otg_bisect.sh` reported all 44 steps identical while `otg_trials.sh`, on
the same code, found `branch_full` varying. The 44 inserted `DO` blocks change plans,
snapshots or timing enough to suppress rare sources. **Use the bisect to localise, never
to certify.**

## 7.3 Probes only sit after `otg_*()` calls

Plain SQL *between* two calls is invisible. This misdirected the investigation three
times — the named step's function turned out innocent and the cause was in the unprobed
statements just before it. If a divergence is attributed to a function that has no
ordering dependency, look at the plain SQL immediately preceding it.

## 7.4 eGon-data does not use a local osmTGmod clone

`import_osm_data` clones from GitHub into `<working-dir>/osmTGmod` and only checks that
the checkout reports `On branch features/egon`. If it does not, it runs
`git checkout features/egon` **without a `cwd`**, i.e. in the wrong directory — an
existing eGon-data bug. To test a fix end-to-end, land the changes on that branch name
inside the working directory's own clone.

## 7.5 `power_script.sql` must not contain `$$` blocks

eGon-data splits that file on every semicolon outside single quotes, which would tear a
dollar-quoted body apart. The file currently contains zero `$$`. Put anything needing a
body into `functions.sql` as a named function.

## 7.6 Stale probe files

`otg_bisect.sh` does not clear old `probe_*.tsv`, so a 2-trial run leaves files from a
previous 10-trial run in place. Filter by timestamp, or delete them first.

---

# 8. Open questions and unverified claims

Stated explicitly so nobody inherits them as settled fact:

1. **The final `branch_data` insert ordering is unverified** (§5.1). Everything else was
   confirmed by a run.
2. **The dangling-bus explanation is high-confidence but unproven** (§4.3). The query
   there settles it.
3. **A 1201-branch outlier** appeared once in 20 SH trials on 2026-09-02 and never
   recurred in 30 subsequent trials. Nothing changed between those runs that touched
   branch counts. Probably belonged to a code state before the last few fixes — but it
   was never explained.
4. **`ST_Collect` ordering in `substation_voronoi.py`** is probably harmless because
   GEOS sorts sites internally. Never tested.
5. **Full DE was never run with all fixes**, only with all-but-the-last.
6. **No electrical validation of the resulting grid** has been done by anyone (§5.6).
