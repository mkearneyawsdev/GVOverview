# GVOverview - Performance Analysis, Redone With Execution Plan Evidence

**Companion to / redo of**: `../v1/GVOverview_Performance_Analysis_Report_v1.md` ("the v1
analysis")
**New input for this pass**: `Execution plan.xml` (in this same folder)
**Status**: Analysis document. The highest-value fix identified below (Issue #3's
`EBillCaseFilter`) has since been implemented in `v3/GVOverview_v3.sql` - see the
"Recommendations Going Forward" section at the end for status of each item.

---

## Important: Which Query This Plan Is Actually For

Before anything else - this needs to be flagged clearly, because it changes how the
findings below should be applied.

**`Execution plan.xml` is a plan for the *original*, pre-refactor `sp_GVOverview`
procedure - the same query `../v1/GVOverview_Performance_Analysis_Report_v1.md`
analyzed - not for `GVOverview_v1.sql` (the refactored static-SQL procedure in this
project's `v1/` folder).**

Evidence: the plan's `StatementText` begins:

```
SELECT
*
FROM (

  SELECT
    pb.[Company],
    pb.[Employee ID],
    ...
```

This "outer `SELECT * FROM ( <big inner SELECT> )`" shape only exists in the
*original* procedure's dynamic-SQL template:

```sql
DECLARE @QUERY NVARCHAR(MAX) = '
SELECT
**COLUMNS**
FROM (
**SELECT**
) AS base
WHERE 0=0
'
```

`GVOverview_v1.sql` and `GVOverview_v2.sql` both query `rpt.vw_ProjectBeneficiary`
directly with no such wrapper - so this plan cannot be either of those. This document
therefore treats the plan as new evidence about **the original query that
`v1/GVOverview_Performance_Analysis_Report_v1.md` already analyzed** ("the v1
analysis" the report you're reading now updates), not as a plan for the refactored
procedure. If a plan for `GVOverview_v1.sql` or `GVOverview_v2.sql` itself is available
separately, that would be a valuable, complementary follow-up capture - it isn't what
this file is.

### Plan Capture Caveats

- **This is an estimated plan, not an actual/measured one** - there is no
  `RunTimeInformation` (actual row counts, actual execution time, actual memory used)
  anywhere in the file. Every number below is the optimizer's *estimate* before
  running the query, not a measured result. Estimates can be wrong, especially where
  cardinality estimation is hard (see Issue #3 below); an **actual** plan (SSMS:
  "Include Actual Execution Plan", or `SET STATISTICS XML ON`) would let
  estimated-vs-actual row counts be compared directly and should be captured as a
  follow-up.
- **Captured for a single, specific parameter set** - the plan shows a residual
  predicate `Company_SK=(1057) AND BeneficiaryIncludedInProject=(1)` pushed all the
  way down to the `Fact_ProjectBeneficiary` clustered index scan, meaning this
  particular call was compiled with `@CompanyIds = '1057'` (a single company) and
  other filters left at their defaults. Findings driven by row multiplication or
  parameter defaults (Issues #3 and #4 below) may look different for other parameter
  combinations - see each issue for what would change.

---

## Executive Summary of What's New

| Original issue | What the plan confirms/changes |
|---|---|
| #21 - "Missing execution plan analysis" | **Resolved by this document** - see full breakdown below |
| #3 - EBill `ROW_NUMBER()` subquery | Confirmed and quantified: forces a **~4.5 million row sort**, ~32% of total query cost. Root cause is more specific than first thought - see below (corrected from an earlier draft of this document) |
| #4 / #9 - View joins / LEFT JOIN row multiplication | Confirmed and quantified: the `vw_StatusDocs` join alone **more than doubles the row count** (222,165 → 491,461) because of how `@Tracked`'s default value behaves |
| #11 - Plan cache pollution from dynamic SQL | Quantified: compiling **this one query text** costs ~2.6 seconds of CPU and ~140 MB of memory - multiplied by however many distinct filter combinations get called |
| #13 - Missing index analysis | Optimizer emitted **zero** missing-index recommendations for this call - the cost is concentrated in a few specific, identifiable places (see below), not general "add more indexes" |
| **New: #23 - Row-Level Security is likely blocking parallelism** | Not in the original 22-issue list at all. The whole query runs single-threaded despite a cost (1153.63) far above the threshold where SQL Server would normally go parallel. This cannot be fixed by rewriting the stored procedure - it needs the security-policy owner |

---

## Issue #21 (Resolved): What the Plan Actually Shows

Top-level statement stats:

| Metric | Value |
|---|---|
| `StatementSubTreeCost` (total optimizer cost) | 1153.63 |
| `StatementEstRows` (estimated rows returned) | 491,461 |
| `CompileTime` | 2,644 ms |
| `CompileCPU` | 2,363 ms |
| `CompileMemory` | 143,928 KB (~140 MB) |
| `DegreeOfParallelism` | **None (serial)** |
| `NonParallelPlanReason` | `CouldNotGenerateValidParallelPlan` |
| `StatementOptmEarlyAbortReason` | **`TimeOut`** |
| Missing index recommendations | **None** |
| Columns with no statistics | **None** |
| `CONVERT_IMPLICIT` warnings | **None** |
| Total plan operators (`RelOp` nodes) | 165 |

For a single company, this query is estimated to return **almost half a million rows**
and costs over 1,150 optimizer cost units to compile a plan for - and that plan
compilation alone burns ~2.6 CPU-seconds and ~140 MB of memory, every time the
dynamic SQL text changes.

Also worth flagging on its own: `StatementOptmEarlyAbortReason="TimeOut"` means the
optimizer did not finish searching the plan space for this query before its time
budget ran out - it returned the best plan it had found so far, not necessarily the
best plan that exists. For a query this complex (165 plan operators), that's not
surprising, but it means the chosen plan shape shouldn't be treated as provably
optimal even for the parts of it that look reasonable; a simpler query (fewer
columns, fewer joined branches) gives the optimizer a better chance of finding a good
plan within its budget, independent of any specific index fix below.

---

## Issue #3 Revisited: The EBill `ROW_NUMBER()` Sort Is ~32% of Total Cost - Corrected

**Correction (superseding an earlier draft of this section)**: this section originally
proposed a `CREATE INDEX ... ON dbo.Fact_EBill (CaseId, [Approved Date] DESC)` as the
fix. Digging into the plan's column-level detail (not just its cost summary) shows
that index cannot do what was claimed - see below for what the evidence actually
supports. The runnable version of what *is* actionable here is in
`v3/GVOverview_v3_Fact_EBill_Index.sql`.

The plan shows this operator chain (reading bottom-up, as data flows):

```
Clustered Index Scan of Fact_EBill, full table (1,208,880 rows)
  -> Hash Match joins to Dim_Company, Dim_Beneficiary, Dim_Project, Dim_User (x2)
     (this is where [Dim_Project].[CaseId] first becomes available)
  -> Sort                (EstRows=4,516,200  Cost=365.34)   <- sorts by CaseId, then ApprovedDate DESC
  -> Window Aggregate     (EstRows=4,516,200  Cost=365.385)  <- computes ROW_NUMBER()
  -> Compute Scalar / Filter -> RN = 1
```

At 365 cost units against a total query cost of 1,153.63, **this branch is
responsible for roughly a third of the entire query's estimated cost** - more than
the 15-25% the original analysis estimated for this issue. That part of the original
finding holds up. Two things about the fix don't:

1. **`CaseId` is not a column on `dbo.Fact_EBill`.** The plan's `Sort/OrderBy` element
   names the sort key explicitly as `[Dim_Project].[CaseId]` - it only exists after
   `Fact_EBill` (via its `Project_SK` column) is joined to `Dim_Project`. A
   `CREATE INDEX` naming a `CaseId` column directly on `Fact_EBill` would fail with
   "invalid column name" - it isn't a valid script to run.
2. **Even an index on `Fact_EBill`'s own `Project_SK` wouldn't reliably remove the
   Sort.** Between the base table and the Sort, the plan uses **Hash Match** joins to
   `Dim_Company`, `Dim_Beneficiary`, `Dim_Project`, and `Dim_User` (twice, for
   manager/assistant lookups). Hash Match does not preserve input row order - so even
   perfectly pre-sorted input from an index would arrive at the Sort in hash-bucket
   order, not `CaseId`/`ApprovedDate` order. `GVOverview_v1_VALIDATION.sql`'s
   commented-out EBill index suggestion, and this document's earlier draft, both
   assumed a simpler join shape than what the plan actually shows.

**What the plan additionally reveals, and what the real fix looks like**: `Fact_EBill`
is read via a full, *unfiltered* Clustered Index Scan here - every row of the entire
table, not just the requested company's. That's because the `EBillLatest` CTE (v1/v2)
- and the equivalent unnamed derived table in the original procedure - computes
`ROW_NUMBER()` over the *entire* `rpt.vw_EBill` view with no company filter at all;
the company filter is only applied later, against `pb`, after the `LEFT JOIN`. This
is true in all three versions (original, v1, v2) equally - it is not something the v1
refactor introduced or fixed. Filtering to one company doesn't change which row is
"latest" for a case in that company, so pushing a company filter into the CTE/subquery
*before* the windowing is logically safe and would let the engine window over a
tiny fraction of the rows it currently processes - this is the highest-value fix
identified for this issue, and it is a query change, not an index.

**What an index can still legitimately help with**: since the base
`Fact_EBill` read is a full scan regardless (no filter is applied to it at that
point), a narrow covering nonclustered index - containing only the columns the
`EBillLatest` computation actually needs (`Project_SK`, `ApprovedDate`, `FeeStatus`)
- lets the engine scan that much smaller structure instead of the full, wide
clustered index. That's a real, low-risk win on the I/O for this one scan
(`EstimateIO` currently 121.9 on the clustered scan); it does **not** remove the Sort.
See `v3/GVOverview_v3_Fact_EBill_Index.sql` for the corrected, runnable script and its
caveats.

---

## Issues #4 / #9 Revisited: The StatusDocs Join Multiplies Row Count by ~2.2x

Reading the row counts through the join tree (top of the plan, where the final result
is assembled):

| Step | Estimated rows |
|---|---|
| Before the `vw_StatusDocs` join (rest of the query's joins) | 222,165 |
| **After** the `LEFT JOIN` to `vw_StatusDocs` (`Hash Match Right Outer Join`) | **491,461** |

That's a **2.2x row multiplication from one join**. The plan shows why: the
`Clustered Index Scan` of `Fact_StatusDocs` (1,086,850 rows) has **no filter predicate
on `[Is Tracking]` at all** - every status/tracking document for a beneficiary is
joined in, not just tracked ones.

This traces back to a real but easy-to-miss detail of how `@Tracked` works, present
in both the original procedure and `GVOverview_v1.sql`/`GVOverview_v2.sql` (all three
implement it the same way):

```sql
-- v1/v2's version of the join condition:
AND (@Tracked = 1 OR sd.[Is Tracking] = 1)
```

`@Tracked` defaults to `1`. Because of the `OR`, **`@Tracked = 1` (the default) means
"no filter is applied at all"** - every document joins in, tracked or not. A caller
would reasonably assume, from the parameter's name and default, that `@Tracked = 1`
means "only tracked documents" - it means the opposite. This is not a bug introduced
by any refactor (the original has the exact same effective behavior via its
`--ONLYTRACKING` placeholder, which is only ever filled in when `@Tracked <> 1`) - but
this plan is the first concrete evidence of its actual cost: **more than doubling the
row count of the entire result set**, for every caller who doesn't explicitly pass
`@Tracked = 0`.

This isn't something to silently "fix" by flipping the default, since that would be a
behavior change existing callers may depend on - but it's worth surfacing explicitly:
either the parameter should be renamed/documented to make its true meaning obvious, or
product/reporting stakeholders should confirm the default is intentional given it
roughly doubles the data volume of every default-parameter call.

---

## Issue #11 Revisited: Plan Cache Cost, Quantified

The original analysis estimated "10-20% wasted memory on plan cache." This plan gives
a concrete anchor: **compiling this one specific dynamic-SQL text costs ~2.6 seconds
of CPU and ~140 MB of memory.** The original procedure builds a distinct SQL string
per unique combination of active filters (company/country/region/case-type/user/
closed-projects/closed-profiles/tracked/dependents/sub-projects - independently
togglable), so the plan cache can hold many separate ~140 MB entries rather than one
reusable plan. On a busy server with varied report parameters, this is a real and
fairly large source of plan-cache/procedure-cache memory pressure, not just a
theoretical concern.

Note this cuts both ways for the *v1 refactor's* choice of `OPTION (RECOMPILE)`
(flagged previously in this project's `v1/` review): recompiling a query in this cost
class **on every single execution** - which is what `RECOMPILE` does - means paying
this ~2.6s/~140MB cost every time, always, rather than once per distinct parameter
combination as the original's ad-hoc caching does. Whether that trade is worth it
depends on how often distinct parameter combinations actually recur in real usage;
this plan doesn't answer that by itself, but it does make the size of the cost
concrete enough to be worth measuring rather than assuming.

---

## Issue #13 Revisited: No Missing-Index Recommendations - the Cost Is Elsewhere

The plan's `<MissingIndexes>` section is empty, and the vast majority of table access
in the plan is via `Index Seek` / `Clustered Index Seek` (18 of the 26 base-table
accesses found), not scans. The original analysis framed this as "potentially 20-40%
of query time spent on table scans" - that framing doesn't match what this plan shows.
The two scans that *do* show meaningful cost are:

- `Fact_EBill` Clustered Index Scan (cost 123.25, 1,208,880 rows) - subsumed by the
  Issue #3 fix above (the right index removes the need to scan+sort in the first
  place)
- `Fact_StatusDocs` Clustered Index Scan (cost 23.96, 1,086,850 rows) - not filterable
  down to a seek by index alone, since (per Issue #4/#9 above) no filter is even being
  applied here for the default `@Tracked = 1` case

So: the general "audit for missing indexes" framing from the original issue #13 isn't
what the evidence supports. The two specific, addressable costs are the EBill sort
(fixed by one new index) and the StatusDocs row multiplication (a parameter-behavior
question, not an indexing one).

---

## New Issue #23: Row-Level Security Is Likely Blocking Parallelism

**This is not in the original 22-issue list.** The plan's
`NonParallelPlanReason="CouldNotGenerateValidParallelPlan"` means SQL Server *wanted*
to consider a parallel plan (the query's cost, 1,153.63, is far above the default cost
threshold for parallelism of 5) but could not produce a valid one, and fell back to
running the entire query on a single thread.

The plan also confirms `SecurityPolicyApplied="true"`, and shows **12 separate joins**
to `Sec.Fact_RowLevelGrants` - one for nearly every base table behind the `rpt.vw_*`
views (`Dim_Beneficiary`, `Dim_Project`, `Fact_ProjectBeneficiary`, `Fact_EBill`,
`Fact_StatusDocs`, `Dim_Company`, `Dim_User`, ...). The procedure also calls
`EXEC sp_set_session_context @key=N'UserId', @value=@UserId;` at the very start, which
is a very strong indicator the row-level security predicate function reads that value
back via `SESSION_CONTEXT('UserId')` to decide grants per row.

This combination - an RLS predicate that depends on `SESSION_CONTEXT()` - is a
documented SQL Server limitation: queries protected by a security predicate of that
shape are frequently ineligible for a parallel plan, regardless of how large or
expensive the query is. If that's what's happening here (this plan doesn't include
the predicate function's own definition, so it can't be fully confirmed from this
file alone), it means **this specific query, and likely every other report or query
running against these same RLS-protected views, is permanently capped at single-core
execution** no matter how it's rewritten at the stored-procedure level.

**Why this matters more than most of the other findings**: none of the SQL-level
fixes in this document, `v1/`, or `v2/` can touch this - it lives in the security
policy bound to the base tables, which sits *below* every view this procedure (in any
version) queries. If parallelism really is being lost to RLS, that's plausibly a
bigger lever than any single query rewrite, because it caps every query against these
tables, not just this one report.

**Recommended next step**: this needs the owner of the Row-Level Security policy/
predicate function, not a change to `GVOverview*.sql`. Concretely:
1. Get the definition of the RLS predicate function(s) bound to the affected tables
2. Confirm whether it references `SESSION_CONTEXT()`/`CONTEXT_INFO()` or another
   construct known to block parallel plans
3. If so, evaluate whether the predicate can be rewritten in a parallel-safe way
   (this is a known, sometimes-solvable problem, not necessarily a permanent
   limitation - but it's a security-policy change, with its own risk profile, and out
   of scope for this SQL-refactoring project to change unilaterally)

---

## Recommendations Going Forward

1. ~~Filter the `EBillLatest` CTE/subquery by the requested company before computing
   `ROW_NUMBER()`.~~ **Implemented in `v3/GVOverview_v3.sql`** via a new
   `EBillCaseFilter` CTE (see that file's header and Phase 4 comments). Apply
   `v3/GVOverview_v3_Fact_EBill_Index.sql`'s covering index alongside it for a
   smaller, complementary win on the base table read (it does not by itself remove
   the Sort - see that script's header for why). **Not yet verified against a real
   execution plan** - this remains estimated/reasoned from the plan evidence, not
   measured; see the note below.
2. **Confirm the `@Tracked` default is intentional** with whoever owns the report's
   requirements, given it roughly doubles row count for every default-parameter call.
   If it is intentional, consider renaming/documenting it so a caller doesn't
   reasonably conclude the opposite from its name.
3. **Escalate the parallelism/RLS question** to the security-policy owner - this is
   the finding with the largest potential blast radius (every query against these
   tables, not just this report) and the one this project's SQL changes cannot fix.
4. **Capture an actual execution plan** (not just estimated) for at least one
   realistic production parameter combination, so estimated-vs-actual row counts can
   be compared and any cardinality-estimation problems (which this file can't reveal
   on its own) can be caught.
5. **When a plan for `GVOverview_v1.sql` or `GVOverview_v2.sql` itself becomes
   available**, re-run this same analysis against it directly - everything above is
   evidence about the pre-refactor query; v1/v2's actual plan shape (no `sp_executeSQL`,
   different join order, CTEs materialized differently) has not been directly observed
   yet and could behave differently in ways this document can't predict.
