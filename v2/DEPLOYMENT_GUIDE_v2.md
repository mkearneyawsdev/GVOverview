# GVOverview_v2 - Deployment Guide

**Companion to**: `../v1/DEPLOYMENT_GUIDE_v1.md`
**Read this first, then follow the v1 guide for anything not called out below** - most
of the deployment mechanics (SQL Server version check, 2012-2014 compatibility
changes, index creation, statistics updates, cutover strategy, rollback plan, and
general troubleshooting) are unchanged between v1 and v2 and are not repeated here.

---

## Quick Summary

### What Changed From v1
`GVOverview_v2.sql` reinstates the custom-fields feature (per-company labeled columns,
e.g. `[CustomProfileValue3:Visa Sponsor]`) that v1 dropped. Deploying v2 adds exactly
one new dependency check and two new test scenarios on top of everything already in
`v1/DEPLOYMENT_GUIDE_v1.md`. Everything else about deploying this procedure is
identical to v1.

### Deployment Time Estimate
Same as v1 (2-3 hours total) plus roughly 15-20 minutes for the additional
dependency check and test scenarios below.

---

## Additional Pre-Deployment Verification (do this in addition to v1 Phase 1)

### Step 1.1a: Verify `Dim_Company` Custom Field Columns

v1's dependency check only confirmed that `dbo.Dim_Company` *exists*. v2 additionally
needs to confirm it has the 100 label columns the procedure reads from:

```sql
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.Dim_Company')
  AND (c.name LIKE 'CustomProfileField%' OR c.name LIKE 'CustomProjectField%')
ORDER BY c.name;
```

**Expected Result**: 100 rows (`CustomProfileField1`..`CustomProfileField50`,
`CustomProjectField1`..`CustomProjectField50`).

**If columns are missing**: `GVOverview_v2.sql` will fail to compile (the `CROSS
APPLY (VALUES (1, c.CustomProfileField1), ...)` block references all 50+50 columns by
name). Do not proceed until this check passes - unlike a missing view/table, a
missing *column* on an existing table is easy to miss by only checking object
existence.

### Step 1.1b: Verify `rpt.vw_ProjectBeneficiary` Custom Value Columns

```sql
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('rpt.vw_ProjectBeneficiary')
  AND (c.name LIKE 'CustomProfileValue%' OR c.name LIKE 'CustomProjectValue%')
ORDER BY c.name;
```

**Expected Result**: 100 rows. These were already part of the view contract before
v1 (the original `GVOverview.sql` reads them), so this should already pass - this
check exists to catch the case where the view was changed between the original
procedure's retirement and this deployment.

### Step 1.1c: Confirm `tempdb` Access

v2 introduces a local temp table (`#Results`) and queries `tempdb.sys.columns`
directly. Confirm the executing account has ordinary `tempdb` read/write permission
(the same permission level any procedure using a `#temp` table already requires - no
elevated permission is needed).

---

## Deployment Steps

Follow `v1/DEPLOYMENT_GUIDE_v1.md` Phases 1-5 as written (dependency verification,
version check, backup, script execution, index creation, statistics update), executing
`GVOverview_v2.sql` in place of `GVOverview_v1.sql` and creating
`[bdp_rpt].[sp_GVOverview_v2]` in place of `sp_GVOverview_v1`. Then run the v1 guide's
8 test scenarios (they exercise filtering/pagination/debug mode, all unchanged in v2)
**plus** the two additional scenarios below before moving to cutover.

### Additional Test Scenario A: Single Company With Custom Fields Configured

```sql
EXEC [bdp_rpt].[sp_GVOverview_v2]
    @UserId = 1,
    @CompanyIds = '<a Company_SK known to have at least one CustomProfileFieldN
                    or CustomProjectFieldN label configured in Dim_Company>',
    @DebugMode = 1;
```

**Expected Result**:
- `PRINT` output shows `CustomFieldsIncluded: YES`
- Result set includes 100 custom columns
- Columns whose corresponding `Dim_Company` slot has a configured label show that
  label in the column name, e.g. `CustomProfileValue3:Visa Sponsor`
- Columns whose slot has no configured label keep the generic name, e.g.
  `CustomProfileValue7`
- Values in labeled/populated columns match `rpt.vw_ProjectBeneficiary`'s
  `CustomProfileValueN`/`CustomProjectValueN` values for that beneficiary/project

**Validation criteria**: Compare this output against the *original* `sp_GVOverview`
(not v1, which has no custom fields at all) run with the same `@CompanyIds` value -
the custom column values and labels should match exactly.

### Additional Test Scenario B: Multiple / Zero Companies Selected

```sql
-- Multiple companies
EXEC [bdp_rpt].[sp_GVOverview_v2] @UserId = 1, @CompanyIds = '<SK1>,<SK2>', @DebugMode = 1;

-- All companies (default)
EXEC [bdp_rpt].[sp_GVOverview_v2] @UserId = 1, @DebugMode = 1;
```

**Expected Result** (both cases):
- `PRINT` output shows `CustomFieldsIncluded: NO (requires exactly one company)`
- All 100 custom columns are present with generic names (no `:Label` suffix)
- All 100 custom columns are `NULL` for every row

**Validation criteria**: This confirms the dynamic relabeling step is correctly
skipped for the common multi-company/all-companies case, and that no company's label
"leaks" into a result set that spans other companies.

### Performance Baseline Addition

When collecting the performance baseline (v1 guide, Phase 6/Test 6.7), capture it
**twice**: once with a single-company `@CompanyIds` value (exercises the Phase 7
dynamic relabeling path) and once with the default all-companies call (exercises only
the static path). Compare both against the equivalent v1 baseline to quantify the
actual cost described qualitatively in `GVOverview_Performance_Analysis_Report_v2.md`.

---

## Rollback

Identical to `v1/DEPLOYMENT_GUIDE_v1.md`'s rollback plan, substituting
`sp_GVOverview_v2` for `sp_GVOverview_v1`:

```sql
DROP PROCEDURE IF EXISTS [bdp_rpt].[sp_GVOverview_v2];
-- Application falls back to sp_GVOverview_v1 or the original sp_GVOverview
```

Since v2 is purely additive relative to v1 in terms of database objects (no schema
changes, no new persisted objects - only a new stored procedure and its transient
`#Results` temp table), rollback carries the same "< 1 minute, no data loss risk"
characteristics already documented for v1.

---

## Troubleshooting (v2-Specific)

### Issue: Custom columns are all NULL even with a single company selected
- Confirm `@CompanyIds` truly resolves to exactly one row in `@Company_SKs` - check
  `DebugMode` output for `CompanyCount: 1`
- Confirm Step 1.1b above passed (the *value* columns must exist on
  `rpt.vw_ProjectBeneficiary`, separately from the *label* columns on `Dim_Company`)

### Issue: Column names show generic names instead of labels, even though `Dim_Company` has labels configured
- Confirm the label text isn't entirely whitespace (Phase 3B treats a
  whitespace-only or empty label the same as "not configured" via
  `NULLIF(LEFT(LTRIM(RTRIM(...)), 100), '')`)
- Confirm the label is on the correct `Company_SK` row - the lookup uses
  `@Company_SK` resolved from `@Company_SKs`, which comes from the caller's
  `@CompanyIds` parameter, not from any other company association on the beneficiary

### Issue: "Invalid column name 'CustomProfileFieldN'" (or `CustomProjectFieldN`) at procedure creation time
- Step 1.1a was skipped or failed - `Dim_Company` is missing one or more of the 100
  expected label columns. The procedure cannot partially compile; all 100 must exist.

### Issue: "Invalid object name '#Results'" when troubleshooting manually
- `#Results` is a local temp table scoped to the procedure's execution - it does not
  exist outside of a single `EXEC` of the procedure and cannot be queried afterward
  from a separate batch/session. This is expected, not a bug.
