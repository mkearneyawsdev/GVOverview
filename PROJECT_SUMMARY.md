# GVOverview Refactoring Project - Overview

**Last updated**: September 22, 2026
**Status**: Four successive refactors of `sp_GVOverview` exist as SQL files
(`v1` through `v4`), none deployed or execution-tested against a live SQL Server
instance yet. Everything below is reasoned from static analysis and (for v3/v4) one
real execution plan - not measured runtime results.

This document is the single entry point for understanding what's happened across the
whole project. Each version folder has its own, more detailed documentation; this
file exists so you don't have to read every one of them to see the overall shape of
the work.

---

## The Story So Far

1. **`GVOverview.sql`** (root, unmodified original) - a 2017-era stored procedure
   that builds its entire query as a dynamic SQL string (`sp_executeSQL`), including
   a 100+ column custom-fields section that dynamically labels columns per company.
2. **`v1/`** - eliminated all dynamic SQL, replacing it with static SQL and
   runtime `(@Flag = 1 OR condition)` filters. This dropped two features as a side
   effect of removing the dynamic-SQL wrapper they depended on: the custom-fields
   feature, and the `@ColumnList` column-subset parameter.
3. **`v2/`** - reinstated custom fields, using a small, isolated, targeted
   dynamic-SQL step (not a return to v1's large dynamic-SQL surface) that only runs
   when exactly one company is selected.
4. **`v3/`** - a real execution plan for the *original* query was captured and
   analyzed in depth. This produced a corrected understanding of where the original's
   cost actually comes from (see "What the Execution Plan Actually Showed" below) and
   one implemented fix: `EBillLatest` now filters by company before computing
   `ROW_NUMBER()`, instead of windowing over the entire warehouse's EBill history on
   every call.
5. **`v4/`** - reinstated the second feature v1 had silently dropped:
   `@ColumnList`, using the same targeted dynamic-SQL pattern v2 established for
   custom fields.

Each version is a strict superset of the previous one's SQL changes (verified by diff
at each step) - v4 contains v3's fix, which contains v2's custom fields, which
contains v1's static-SQL rewrite.

---

## Version Comparison

| | Original | v1 | v2 | v3 | v4 |
|---|---|---|---|---|---|
| Dynamic SQL | Entire query built as a string | None | Small, targeted (custom-field labels, single-company only) | Same as v2 | Same as v2, extended to also cover `@ColumnList` |
| Custom fields | ✅ Yes | ❌ Dropped | ✅ Reinstated | ✅ (unchanged) | ✅ (unchanged) |
| `@ColumnList` | ✅ Yes | ❌ Dropped | ❌ (still dropped) | ❌ (still dropped) | ✅ Reinstated |
| `EBillLatest` company filter | ❌ No (windows over entire warehouse) | ❌ No | ❌ No | ✅ Yes | ✅ (unchanged) |
| Lines of code | 755 | 565 | 794 | 848 | 925 |
| Has a dedicated doc set (summary/syntax/deployment/performance) | N/A | ✅ | ✅ | ❌ (analysis doc only) | ✅ |

---

## What the Execution Plan Actually Showed

`v3/Execution plan.xml` is a real (estimated, not actual) plan for the *original*
query, captured for a single-company call. Digging into it corrected several
assumptions the original analysis (`v1/GVOverview_Performance_Analysis_Report_v1.md`)
had made without real evidence:

- **The `EBillLatest`/`ROW_NUMBER()` computation was ~32% of total query cost** -
  more than originally estimated (15-25%) - but the original's proposed fix
  (wrap it in a CTE) doesn't actually help; a CTE is optimizer-equivalent to a
  subquery. The real cause was that the computation was never filtered by company at
  all. **This is the one fix that's been implemented** (v3's `EBillCaseFilter`).
- **A proposed index on `Fact_EBill(CaseId, ...)` would have failed outright** -
  `CaseId` isn't a column on that table; it's joined in from `Dim_Project`. A
  corrected, narrower index script exists
  (`v3/GVOverview_v3_Fact_EBill_Index.sql`) but has **not been run or verified** -
  it also does not eliminate the Sort, because Hash Match joins between the two
  tables destroy row order regardless of indexing.
- **The `vw_StatusDocs` join roughly doubles row count** (222,165 → 491,461 in the
  captured plan) because `@Tracked = 1` (the default, in every version including
  original) applies no filter at all, despite its name suggesting the opposite.
  Not changed in any version - flagged as a question for whoever owns the report's
  requirements, not silently "fixed."
- **The whole query runs single-threaded** despite a cost far above the normal
  parallelism threshold, most likely because Row-Level Security predicates read
  `SESSION_CONTEXT('UserId')` - a known SQL Server limitation. This cannot be fixed
  by changing this stored procedure at all; it would need the RLS policy owner.
- **The query optimizer's search timed out** (`StatementOptmEarlyAbortReason=TimeOut`)
  before finishing - for a query this complex (165 plan operators), the chosen plan
  shouldn't be assumed provably optimal even where it looks reasonable.

Full detail: `v3/GVOverview_Performance_Analysis_Report_v3.md`.

---

## What's Been Verified, and What Hasn't

**Verified** (structural/static checks only - no SQL Server instance available in
this environment):
- Each version's core query logic (filters, joins, CTEs, pagination) diffed against
  the previous version and confirmed unchanged except for the documented, intentional
  differences
- Parentheses/brackets balanced in every `.sql` file
- The custom-fields and `@ColumnList` dynamic-SQL steps traced through all relevant
  parameter-combination branches by hand

**Not verified** (would require a real SQL Server instance):
- That any of `v1.sql` through `v4.sql` actually compiles
- That `v3`'s `EBillCaseFilter` fix measurably reduces the `EBillLatest` cost in
  practice (the whole reason it was proposed is reasoned from the original query's
  plan, not measured against v3/v4's own plan, which doesn't yet exist)
- That `v3/GVOverview_v3_Fact_EBill_Index.sql` has any real-world effect
- Result-set equivalence between any refactored version and the original, for any
  real parameter combination

---

## Open Questions and Outstanding Items

These are carried forward from each version's own documentation - nothing here is
new, this just collects them in one place:

1. **Capture a fresh execution plan for `v3.sql`/`v4.sql`** (not just the original)
   to confirm the `EBillCaseFilter` fix actually reduces cost, and to check whether
   the `@AllCompanies = 1` case is optimized away as hoped.
2. **Decide whether to run `v3/GVOverview_v3_Fact_EBill_Index.sql`** in a test/
   staging environment - a legitimate, smaller win independent of the above.
3. **Confirm whether `@Tracked`'s default behavior is intentional** with whoever
   owns the report's requirements, given it roughly doubles row count for every
   default-parameter call.
4. **Escalate the Row-Level Security / parallelism finding** to the security-policy
   owner - the single largest-blast-radius finding, and the one this project's SQL
   changes cannot address at all.
5. **Deploy and test against a real environment** - everything above is reasoned
   from static analysis and one captured plan; none of it has been confirmed against
   actual execution.

---

## Where Everything Lives

```
GVOverview/
├── PROJECT_SUMMARY.md          (this file)
├── CONVERSATION_LOG.txt        (full session-by-session working log)
├── GVOverview.sql              (original - reference only, unmodified)
├── v1/                         (static SQL; custom fields and @ColumnList dropped)
│   ├── GVOverview_v1.sql, GVOverview_v1_VALIDATION.sql
│   └── REFACTORING_SUMMARY_v1.md, DEPLOYMENT_GUIDE_v1.md,
│       GVOverview_v1_SYNTAX_ANALYSIS.md, GVOverview_Performance_Analysis_Report_v1.md
├── v2/                         (+ custom fields reinstated)
│   ├── GVOverview_v2.sql
│   └── REFACTORING_SUMMARY_v2.md, DEPLOYMENT_GUIDE_v2.md,
│       GVOverview_v2_SYNTAX_ANALYSIS.md, GVOverview_Performance_Analysis_Report_v2.md
├── v3/                         (+ EBillLatest company filter, execution-plan-driven)
│   ├── GVOverview_v3.sql, GVOverview_v3_Fact_EBill_Index.sql, Execution plan.xml
│   └── GVOverview_Performance_Analysis_Report_v3.md  (no separate deployment/syntax/
│       summary docs - this version came from analysis work, not a doc request)
└── v4/                         (+ @ColumnList reinstated)
    ├── GVOverview_v4.sql
    └── REFACTORING_SUMMARY_v4.md, DEPLOYMENT_GUIDE_v4.md,
        GVOverview_v4_SYNTAX_ANALYSIS.md, GVOverview_Performance_Analysis_Report_v4.md
```

For the full session-by-session record of who asked for what and exactly what was
done, see `CONVERSATION_LOG.txt`. For any single version's detail, start with that
version's `REFACTORING_SUMMARY_vN.md` (or, for v3, `GVOverview_Performance_Analysis_Report_v3.md`).
