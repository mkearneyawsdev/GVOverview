# GVOverview SQL Stored Procedure Refactoring Project - V4 COMPLETION SUMMARY

**Project Date**: September 22, 2026
**Status**: ✅ **COMPLETE - CODE WRITTEN, NOT YET DEPLOYED OR EXECUTION-TESTED**
**SQL Server Target**: 2016+ (same target as v1/v2/v3)
**Builds on**: `../v2/REFACTORING_SUMMARY_v2.md` (custom fields) and
`../v3/GVOverview_Performance_Analysis_Report_v3.md` (EBillLatest company filter)

---

## Why v4 Exists

While confirming the custom-fields reinstatement in v2, a second dropped feature was
found: `@ColumnList` - a parameter that lets a caller request only specific columns
back, instead of the full ~140+100-column result set. It was declared in every
version's parameter list (v1 through v3) but never wired up to anything - a silent
casualty of removing the original's dynamic-SQL wrapper, the same way custom fields
were, just not noticed until later.

v4 reinstates it, using the same design pattern v2 already established for custom
fields: keep the bulk of the query fully static, and extend the one small, existing,
targeted dynamic-SQL step (Phase 7) rather than reintroducing dynamic SQL anywhere
else.

---

## What Changed From v3 (and What Didn't)

### Unchanged from v3 (verified byte-identical by diff)
- Parameter validation and normalization for every filter except `@ColumnList`
- `EBillCaseFilter` / `EBillLatest` / `ProjectData` / `ProcessDetailData` CTEs
- All JOIN conditions
- The entire runtime-condition `WHERE` clause
- Deterministic pagination (`ORDER BY` / `OFFSET`-`FETCH`)
- `OPTION (RECOMPILE, MAXDOP 4)` query hint
- Custom-field label resolution (Phase 3B) and value selection (the 100 `CASE`
  columns in the main `SELECT`)

### New in v4
| Addition | Purpose |
|---|---|
| Phase 2B: `@ColumnList` normalization | Splits the caller's comma-separated list into a `@RequestedColumns` table variable, stripping brackets per-item |
| `@HasColumnFilter` flag | Set once, reused everywhere the procedure needs to know whether a real column filter is active |
| Phase 7 extension | The existing custom-field-labeling dynamic-SQL step now also runs when `@HasColumnFilter = 1`, and its column list is filtered down to the requested set |
| Empty-match fallback | If none of the requested names match a real column, the filter is dropped and every column is returned |

### Explicitly Not Changed
- The fast static `SELECT * FROM #Results` path (v1's original design) still runs
  whenever neither custom-field labeling nor column filtering is needed - the common
  case (multi-company or all-companies, no `@ColumnList`) pays no dynamic-SQL cost at
  all, same as v1/v2/v3.

---

## `@ColumnList` Behavior

| Input | Result |
|---|---|
| `NULL` or empty (default) | Every column returned, same as v1/v2/v3 |
| Comma-separated names, with or without `[brackets]` | Only those columns returned, in `#Results`' original column order |
| Names that don't match any real column | Silently excluded from filtering (not from an error) |
| **None** of the requested names match anything | The whole filter is ignored; every column is returned |
| A custom-field base name (e.g. `CustomProfileValue3`) | Matches and is included; returned under its labeled alias if exactly one company was also selected, same as it would be without `@ColumnList` |
| A custom-field's *labeled* alias (e.g. `CustomProfileValue3:Visa Sponsor`) | **Does not match** - see Known Limitation below |

This mirrors the original procedure's intent (return a caller-chosen subset of
columns) without reviving its brittle, all-or-nothing bracket-detection logic or its
reliance on string-replacing a placeholder inside a hand-built query string.

### Known Limitation: Custom-Field Labels

`@ColumnList` is matched against `#Results`' actual stored column names
(`CustomProfileValue3`), not the display alias a caller sees in the final output
(`CustomProfileValue3:Visa Sponsor`) - the label text isn't known until Phase 7 has
already decided which columns survive the filter. A caller wanting a specific custom
field back should request it by its base name. This is documented directly in
`GVOverview_v4.sql`'s header and is not expected to surprise anyone reading the
column list returned by a `@DebugMode = 1` or "all columns" call first.

---

## Dynamic SQL: What Changed About When It Runs

v2 and v3 only paid Phase 7's dynamic-SQL cost when exactly one company was selected
(for custom-field labels). v4 widens that condition to *also* include "a valid
`@ColumnList` was supplied" - so a multi-company call that also requests a column
subset now takes the dynamic path too, where it previously wouldn't have. This is a
deliberate, expected tradeoff: the whole point of the feature is to let a caller
avoid pulling back ~240 columns when they only want a handful, and that requires the
same "column identity is part of the compiled query shape" dynamic-SQL step already
used for custom-field labels - there's no way to get variable column *selection*
without it. See `GVOverview_Performance_Analysis_Report_v4.md` for the cost/benefit
detail.

---

## Validation Status

✅ Structural checks performed (no SQL Server instance available in this environment):
- Parentheses and square-bracket counts balanced
- The entire `FROM`/`JOIN`/`WHERE`/`ORDER BY`/pagination block diffed against
  `v3/GVOverview_v3.sql` and confirmed byte-identical

⚠️ Not yet done (see `DEPLOYMENT_GUIDE_v4.md`):
- Actual compilation against a live SQL Server instance
- Execution testing of `@ColumnList` with real data - valid subsets, bracket and
  non-bracket input, invalid/nonexistent names, and combined with a single-company
  custom-fields call
- Everything already flagged as outstanding in v3 (fresh execution plan for the
  `EBillCaseFilter` fix, the `Fact_EBill` index, the `@Tracked` default question, the
  RLS/parallelism escalation) remains outstanding - v4 does not touch any of it

---

## File Locations

```
GVOverview/
├── GVOverview.sql                          (original - reference only)
├── v1/  (static SQL, no custom fields)
├── v2/  (+ custom fields)
├── v3/  (+ EBillLatest company filter, execution-plan-driven)
└── v4/
    ├── GVOverview_v4.sql                   (+ @ColumnList - THIS VERSION)
    ├── GVOverview_v4_SYNTAX_ANALYSIS.md
    ├── DEPLOYMENT_GUIDE_v4.md
    ├── GVOverview_Performance_Analysis_Report_v4.md
    └── REFACTORING_SUMMARY_v4.md            (this file)
```

---

## Next Steps

1. Review `GVOverview_v4.sql` and this documentation set
2. Deploy to staging and run the test scenarios in `DEPLOYMENT_GUIDE_v4.md`,
   including the `@ColumnList`-specific scenarios and the carried-over v3 scenarios
   (this is the first deployment guide to cover the v3 `EBillCaseFilter` change,
   since v3 didn't have its own deployment guide)
3. Capture a fresh execution plan to confirm the `EBillCaseFilter` fix's real-world
   effect (still outstanding from v3)
4. Decide on the still-open v3 items: the `Fact_EBill` covering index, the
   `@Tracked` default question, and the RLS/parallelism escalation

---

*This document is the v4 counterpart to `v2/REFACTORING_SUMMARY_v2.md` and
`v3/GVOverview_Performance_Analysis_Report_v3.md` - it does not repeat their content
where unchanged.*
