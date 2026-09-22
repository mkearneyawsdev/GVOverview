# GVOverview SQL Stored Procedure Refactoring Project - V2 COMPLETION SUMMARY

**Project Date**: September 22, 2026
**Status**: ✅ **COMPLETE - CODE WRITTEN, NOT YET DEPLOYED OR EXECUTION-TESTED**
**SQL Server Target**: 2016+ (same target as v1)
**Builds on**: `../v1/REFACTORING_SUMMARY_v1.md`

---

## Why v2 Exists

v1 (September 15, 2026) eliminated all dynamic SQL from `sp_GVOverview` for a 30-50%
estimated performance gain, but in doing so it silently dropped the **custom fields**
feature: per-company custom Profile/Project columns whose *display label* is configured
in `dbo.Dim_Company` and embedded directly into the result column name (e.g.
`[CustomProfileValue3:Visa Sponsor]`). That label-in-column-name behavior cannot be
expressed in pure static SQL, since a column alias cannot be parameterized - which is
presumably why the original 2017 procedure needed dynamic SQL for this piece in the
first place.

v2 reinstates this feature with the original's exact output behavior, while keeping
every other part of v1's static-SQL design unchanged.

---

## What Changed From v1 (and What Didn't)

### Unchanged from v1 (verified byte-identical by diff)
- Parameter validation and normalization (Phases 1-2)
- Filter table variable population (Phase 3)
- All three CTEs (`EBillLatest`, `ProjectData`, `ProcessDetailData`)
- All JOIN conditions
- The entire runtime-condition `WHERE` clause
- Deterministic multi-key `ORDER BY` / `OFFSET`-`FETCH` pagination
- `OPTION (RECOMPILE, MAXDOP 4)` query hint

### New in v2
| Addition | Purpose |
|---|---|
| Phase 3B: custom field label resolution | Reads `dbo.Dim_Company`'s 50 Profile + 50 Project label columns for the single selected company, unpivoted into a table variable via `CROSS APPLY (VALUES ...)` |
| 100 `CustomProfileValueN` / `CustomProjectValueN` columns in the main SELECT | Reinstated as `CASE WHEN @CompanyCount = 1 THEN ... ELSE NULL END` expressions - still 100% static SQL |
| `#Results` temp table | The main static query now lands its paginated output here instead of returning directly, so Phase 7 can relabel columns without re-running the joins/filters |
| Phase 7: targeted dynamic relabeling | A short `sp_executeSQL` call that renames only the 100 custom columns using `tempdb.sys.columns` metadata + `QUOTENAME()`-escaped labels from `Dim_Company`. Runs **only** when exactly one company is selected; otherwise a plain static `SELECT * FROM #Results` is used |

### Explicitly Not Changed
- `@ColumnList` remains an unused, dead parameter (was already dead in v1 - see
  `GVOverview_v2_SYNTAX_ANALYSIS.md` for details). Reinstating the column-subset
  feature it originally supported was out of scope for this pass.

---

## Custom Fields Behavior (Restored to Match the Original Exactly)

| `@CompanyIds` selection | Custom column values | Custom column names |
|---|---|---|
| Exactly one company | Real values from `pb.[CustomProfileValueN]` / `pb.[CustomProjectValueN]` | Labeled, e.g. `[CustomProfileValue3:Visa Sponsor]`, when that company has configured a label for the slot; generic name if not |
| Zero companies (`ALL`) or more than one | `NULL` for all 100 columns | Generic (`[CustomProfileValue1]`, etc.) |

This table is identical to the original 2017 procedure's behavior. The rationale
(carried over unchanged): a label is company-specific, so attaching it to a result set
spanning multiple companies would be ambiguous or misleading.

---

## Dynamic SQL: How Much Came Back, and Why It's Safe

v1's whole point was eliminating ~300 lines of dynamic SQL that built the *entire*
query (filters, joins, pagination, and column list) as a string executed via
`sp_executeSQL`. v2 does **not** revert that. The only dynamic SQL in v2 is:

1. Scoped to a single, short `SELECT ... FROM #Results` statement - it never touches
   filtering, joins, or pagination, which all still run as static SQL against the base
   views.
2. Skipped entirely (falls back to a plain static `SELECT *`) unless exactly one
   company is selected - the common "all companies" / multi-company report case pays
   no dynamic-SQL cost at all.
3. Built only from `dbo.Dim_Company` label text and `#Results`' own column metadata -
   never from `@CompanyIds`, `@ColumnList`, or any other caller-supplied parameter -
   and every identifier is passed through `QUOTENAME()` before being spliced into the
   SQL string, which neutralizes bracket-based injection attempts.

See `GVOverview_Performance_Analysis_Report_v2.md` for the performance implications of
this design versus a fully-static (no-relabeling) alternative.

---

## Validation Status

✅ Structural checks performed (no SQL Server instance available in this environment):
- Parentheses and square-bracket counts balanced
- `BEGIN`/`END` block counts matched
- Shared sections (parameter handling, CTEs, JOINs, WHERE, ORDER BY, pagination) diffed
  against `v1/../GVOverview_v1.sql` and confirmed unchanged

⚠️ Not yet done (see `DEPLOYMENT_GUIDE_v2.md`):
- Actual compilation against a live SQL Server instance
- Execution testing with real `dbo.Dim_Company` data (single company, multiple
  companies, and zero-companies-selected cases)
- Result-set comparison against the original `sp_GVOverview` for a company with
  custom fields configured

---

## File Locations

```
GVOverview/
├── GVOverview.sql              (original - reference only)
├── GVOverview_v1.sql           (v1 - static SQL, no custom fields)
├── GVOverview_v1_VALIDATION.sql
├── GVOverview_v2.sql           (v2 - static SQL + custom fields reinstated - THIS VERSION)
├── v1/
│   ├── DEPLOYMENT_GUIDE_v1.md / .docx
│   ├── GVOverview_Performance_Analysis_Report_v1.md / .docx
│   ├── GVOverview_v1_SYNTAX_ANALYSIS.md / .docx
│   └── REFACTORING_SUMMARY_v1.md / .docx
└── v2/
    ├── DEPLOYMENT_GUIDE_v2.md
    ├── GVOverview_Performance_Analysis_Report_v2.md
    ├── GVOverview_v2_SYNTAX_ANALYSIS.md
    └── REFACTORING_SUMMARY_v2.md   (this file)
```

---

## Next Steps

1. Review `GVOverview_v2.sql` and this documentation set
2. Verify `dbo.Dim_Company` has the 50+50 custom field label columns the procedure
   expects (see `DEPLOYMENT_GUIDE_v2.md`, Phase 1)
3. Deploy to staging and run the test scenarios in `DEPLOYMENT_GUIDE_v2.md`
4. Compare custom-field output against the original `sp_GVOverview` for at least one
   company with labels configured
5. Decide whether `@ColumnList` should also be reinstated in a future v3

---

*This document is the v2 counterpart to `v1/REFACTORING_SUMMARY_v1.md` and should be
read alongside it - it does not repeat v1 content that is unchanged.*
