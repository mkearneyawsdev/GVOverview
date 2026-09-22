# GVOverview - Performance Analysis, Redone With Execution Plan Evidence

**Companion to / redo of**: `../v1/GVOverview_Performance_Analysis_Report_v1.md` ("the v1
analysis")
**New input for this pass**: `Execution plan.xml` (in this same folder)
**Status**: Analysis only - no code changes in this document. Findings here are the
input for whatever gets built next.

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
| #3 - EBill `ROW_NUMBER()` subquery | Confirmed and quantified: forces a **~4.5 million row sort**, ~32% of total query cost. The original's recommended fix (wrap in a CTE) does **not** fix this - see below |
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
| Missing index recommendations | **None** |
| Columns with no statistics | **None** |
| `CONVERT_IMPLICIT` warnings | **None** |
| Total plan operators (`RelOp` nodes) | 165 |

For a single company, this query is estimated to return **almost half a million rows**
and costs over 1,150 optimizer cost units to compile a plan for - and that plan
compilation alone burns ~2.6 CPU-seconds and ~140 MB of memory, every time the
dynamic SQL text changes.

---

## Issue #3 Revisited: The EBill `ROW_NUMBER()` Sort Is ~32% of Total Cost, and a CTE Doesn't Fix It

The plan shows this operator chain (reading bottom-up, as data flows):

```
Clustered/Index scan of Fact_EBill (base rows)
  -> Sort                (EstRows=4,516,200  Cost=365.34)
  -> Window Aggregate     (EstRows=4,516,200  Cost=365.385)   <- computes ROW_NUMBER()
  -> Compute Scalar / Filter -> RN = 1
```

**The `Sort` here is sorting an estimated 4.5 million rows** so that
`ROW_NUMBER() OVER (PARTITION BY CaseId ORDER BY [Approved Date] DESC)` can be
computed. At 365 cost units against a total query cost of 1,153.63, **this single
branch is responsible for roughly a third of the entire query's estimated cost** -
more than the 15-25% the original analysis estimated for this issue.

**Important correction to the original recommendation**: `v1/GVOverview_Performance_Analysis_Report_v1.md`'s
fix for this issue was to wrap the subquery in a CTE (which `GVOverview_v1.sql` did
adopt - it's the `EBillLatest` CTE). A CTE and a derived-table subquery are logically
identical to the optimizer, so **rewriting this as a CTE has no effect on this Sort
operator by itself.** The sort exists because there's no index on the underlying
`Fact_EBill` table that already presents rows in `(CaseId, [Approved Date] DESC)`
order - the *only* thing that removes this cost is that index:

```sql
CREATE INDEX IX_Fact_EBill_CaseId_ApprovedDate
  ON dbo.Fact_EBill (CaseId, [Approved Date] DESC)
  INCLUDE ([Fee Status]);
```

With that index in place, SQL Server can walk `Fact_EBill` already in the order the
window function needs and compute `ROW_NUMBER()` as a stream, eliminating the sort
entirely. `GVOverview_v1_VALIDATION.sql`'s "recommended indexes" section already
listed an EBill index as a commented-out suggestion ("if view is based on table") -
this plan confirms it's not optional, it's the single biggest lever available on this
query.

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

1. **Add the `Fact_EBill (CaseId, [Approved Date] DESC) INCLUDE ([Fee Status])`
   index.** This is the single highest-confidence, lowest-risk fix identified here -
   it removes a sort estimated at ~32% of total query cost and doesn't change any
   query logic in any version (original, v1, or v2 all compute the same ROW_NUMBER()
   window).
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
