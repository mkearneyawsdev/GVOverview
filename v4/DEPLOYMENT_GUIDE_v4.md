# GVOverview_v4 - Deployment Guide

**Companion to**: `../v2/DEPLOYMENT_GUIDE_v2.md`
**Read this first, then follow the v2 guide for anything not called out below** -
version check, 2012-2014 compatibility, index creation, statistics updates, cutover
strategy, rollback plan, and general troubleshooting are unchanged since v2.

**Note**: `v3/` never got its own deployment guide (it was produced directly from
execution-plan analysis rather than a documentation request). This is therefore also
the **first** deployment guide covering v3's `EBillCaseFilter` change - see the
carried-over test scenario below.

---

## Quick Summary

### What Changed Since v2
`GVOverview_v4.sql` adds two things on top of `v2.sql`: v3's `EBillCaseFilter` fix
(narrows the EBillLatest windowing to the requested company before computing
`ROW_NUMBER()`) and v4's own `@ColumnList` reinstatement (return only the caller's
requested columns). Deploying v4 means deploying both changes at once, since no
intermediate v3 deployment guide exists.

### Deployment Time Estimate
Same as v2 (2-3 hours total) plus roughly 15 minutes for the `@ColumnList` test
scenarios below, and the fresh execution-plan capture recommended for the carried-over
`EBillCaseFilter` verification (still outstanding since v3 - see
`v3/GVOverview_Performance_Analysis_Report_v3.md`).

---

## Pre-Deployment Verification

No new dependency checks beyond `v2/DEPLOYMENT_GUIDE_v2.md`'s Steps 1.1a-1.1c
(`Dim_Company` custom field columns, `rpt.vw_ProjectBeneficiary` custom value
columns, `tempdb` access) - `@ColumnList` and `EBillCaseFilter` both work entirely
against objects already verified there (`#Results`' own metadata, and
`rpt.vw_ProjectBeneficiary`'s `company_sk`/`CaseId`/`BeneficiaryIncludedInProject`
columns, which the main query already depends on).

---

## Deployment Steps

Follow `v2/DEPLOYMENT_GUIDE_v2.md`'s Phases 1-5 as written, executing
`GVOverview_v4.sql` in place of `GVOverview_v2.sql` and creating
`[bdp_rpt].[sp_GVOverview_v4]` in place of `sp_GVOverview_v2`. Then run v2's 8 base
test scenarios plus its two custom-field scenarios (all unchanged in v4), **plus**
the scenarios below.

### Carried-Over Test Scenario: `EBillCaseFilter` (from v3, not yet formally tested)

```sql
-- Single company - EBillLatest should now only window over this company's cases
EXEC [bdp_rpt].[sp_GVOverview_v4] @UserId = 1, @CompanyIds = '<a real Company_SK>', @DebugMode = 1;

-- All companies (default) - EBillLatest still windows over everything (see v3 notes)
EXEC [bdp_rpt].[sp_GVOverview_v4] @UserId = 1, @DebugMode = 1;
```

**Expected Result**: Both calls return the same `[Bills Pending Approval]` values as
the equivalent v2 (or original) call would, for the cases in scope - this is a
performance change, not a behavior change, so result *content* should be identical.

**Validation criteria**: Capture an actual execution plan for the single-company call
and compare the `EBillLatest` branch's estimated row count and cost against
`v3/Execution plan.xml`'s baseline (4,516,200 rows / 365 cost units). A meaningfully
smaller number confirms the fix is working; an unchanged number means the
`EXISTS`/`@AllCompanies` guard isn't being evaluated the way expected and needs
investigation before this ships. This has **not** been done in this environment (no
SQL Server instance available) - treat it as a required step, not optional.

### New Test Scenario: `@ColumnList` - Valid Subset

```sql
EXEC [bdp_rpt].[sp_GVOverview_v4]
    @UserId = 1,
    @ColumnList = 'Company,Employee ID,Case Type,Full Name Last First Middle',
    @DebugMode = 1;
```

**Expected Result**: Result set contains exactly those 4 columns, in `#Results`'
original left-to-right order (not necessarily the order requested).
`DebugMode` output shows `ColumnFilterApplied: YES`.

### New Test Scenario: `@ColumnList` - Bracketed Input

```sql
EXEC [bdp_rpt].[sp_GVOverview_v4]
    @UserId = 1,
    @ColumnList = '[Company],[Employee ID]',
    @DebugMode = 1;
```

**Expected Result**: Identical result to the unbracketed equivalent - confirms
per-item bracket stripping works regardless of whether the caller includes them.

### New Test Scenario: `@ColumnList` - No Matches (Fallback)

```sql
EXEC [bdp_rpt].[sp_GVOverview_v4]
    @UserId = 1,
    @ColumnList = 'NotARealColumn,AlsoNotReal',
    @DebugMode = 1;
```

**Expected Result**: All columns are returned (the filter is dropped, not applied as
an empty projection). `DebugMode` output shows
`ColumnFilterApplied: NO (no requested column matched - returned all columns)`.

### New Test Scenario: `@ColumnList` Combined With Single-Company Custom Fields

```sql
EXEC [bdp_rpt].[sp_GVOverview_v4]
    @UserId = 1,
    @CompanyIds = '<a Company_SK with at least one custom field label configured>',
    @ColumnList = 'Company,CustomProfileValue1',
    @DebugMode = 1;
```

**Expected Result**: Result set contains exactly `Company` and the custom field
column, and if that company has a label configured for slot 1, the returned column
name is `CustomProfileValue1:<label>` - confirms filtering (by base name) and
labeling compose correctly. `DebugMode` output shows both
`CustomFieldsIncluded: YES` and `ColumnFilterApplied: YES`.

### Performance Baseline Addition

When collecting the performance baseline (v2 guide's Test 6.7 equivalent), capture it
for at least one `@ColumnList`-filtered call and compare against the equivalent
unfiltered call, to confirm the expected reduction in bytes returned
(`GVOverview_Performance_Analysis_Report_v4.md`'s "Benefit" section) actually shows up
- and that Phase 7's now-more-frequent dynamic compilation doesn't introduce
noticeable latency for typical `@ColumnList` sizes.

---

## Rollback

Identical to `v2/DEPLOYMENT_GUIDE_v2.md`'s rollback plan, substituting
`sp_GVOverview_v4` for `sp_GVOverview_v2`:

```sql
DROP PROCEDURE IF EXISTS [bdp_rpt].[sp_GVOverview_v4];
-- Application falls back to sp_GVOverview_v3, sp_GVOverview_v2, or the original sp_GVOverview
```

Same "< 1 minute, no data loss risk" characteristics as prior versions - v4 adds no
new persisted objects.

---

## Troubleshooting (v4-Specific)

### Issue: `@ColumnList` request returns all columns instead of the requested subset
- Confirm at least one requested name matches a column in the unfiltered result set
  exactly (case per the database's default collation) - use a `@ColumnList = NULL`
  call first to see the exact available column names
- Confirm the name isn't a custom field's *labeled* alias
  (`CustomProfileValue3:Visa Sponsor`) - filter on the base name
  (`CustomProfileValue3`) instead; see `GVOverview_v4.sql`'s header notes

### Issue: `@ColumnList` request returns an error instead of a filtered result
- This procedure is designed not to error on unmatched column names (they're silently
  dropped from the filter). An error means something else is wrong - check
  `@ColumnList` for characters that would break `STRING_SPLIT`'s comma delimiter
  (e.g. a column name that itself legitimately contains a comma, which none of this
  procedure's column names do)

### Issue: `EBillLatest`/`[Bills Pending Approval]` values differ from v2/v3
- They should not - `EBillCaseFilter` changes *how many rows* are windowed, not
  *which bill* ends up as `RN = 1` for any case still in scope. If values differ,
  treat this as a correctness bug and stop deployment - compare against the v2/v3
  Test Scenario B (multiple/zero companies) output for the same parameters
