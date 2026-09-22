# GVOverview_v4.sql - Syntax & Logic Analysis

**Companion to**: `../v2/GVOverview_v2_SYNTAX_ANALYSIS.md` (custom-field labeling
syntax, still applicable unchanged) and `../v3/GVOverview_Performance_Analysis_Report_v3.md`
(the `EBillCaseFilter`/`EBillLatest` change, analyzed there instead of a dedicated v3
syntax document).
**Scope of this document**: Only the parts of `GVOverview_v4.sql` that differ from
`GVOverview_v3.sql` - Phase 2B and the Phase 7 extension. Parameter handling, CTEs,
JOINs, WHERE clause, ORDER BY/OFFSET/FETCH, OPTION hint, and the custom-field label
resolution/selection logic were diffed byte-for-byte against v3 and are unchanged.

---

## New Section 1: Phase 2B - `@ColumnList` Normalization

```sql
DECLARE @RequestedColumns TABLE (ColumnName NVARCHAR(128) PRIMARY KEY);

IF @ColumnList IS NOT NULL AND LEN(LTRIM(RTRIM(@ColumnList))) > 0
BEGIN
    INSERT INTO @RequestedColumns (ColumnName)
    SELECT DISTINCT LTRIM(RTRIM(REPLACE(REPLACE([Value], '[', ''), ']', '')))
    FROM STRING_SPLIT(@ColumnList, ',')
    WHERE LEN(LTRIM(RTRIM(REPLACE(REPLACE([Value], '[', ''), ']', '')))) > 0;
END

DECLARE @HasColumnFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @RequestedColumns) THEN 1 ELSE 0 END;
```

**[✓] PASS - Table variable with `PRIMARY KEY`**: `ColumnName NVARCHAR(128) PRIMARY KEY`
gives the table variable a unique clustered index on the column being matched later,
and doubles as a cheap guard against inserting the same normalized name twice (though
`SELECT DISTINCT` already prevents that at the source).

**[✓] PASS - `STRING_SPLIT` + `REPLACE`-based bracket stripping**: Each item is
processed independently - `REPLACE(REPLACE([Value], '[', ''), ']', '')` removes any
`[` or `]` characters from that one item, then `LTRIM(RTRIM(...))` trims whitespace.
This is a correction of the *original* procedure's bracket-handling
(`IF CHARINDEX('[',@ColumnList) = 0 SET @ColumnList = '[' + REPLACE(@ColumnList,',','],[') + ']'`),
which only wrapped the *entire* list in brackets if *none* of it already contained a
`[` - a caller mixing bracketed and unbracketed names in one call would have gotten
inconsistent results from the original. Per-item stripping has no such failure mode.

**[✓] PASS - Empty-string filtering**: The `WHERE LEN(LTRIM(RTRIM(...))) > 0` clause
means a trailing comma, double comma, or all-whitespace entry (e.g. `"Company,,  ,"`)
does not insert an empty-string row into `@RequestedColumns`, which would otherwise
never match any real column name and would be silently harmless but pointless to
carry through the rest of the procedure.

**[✓] PASS - No SQL injection surface**: `@ColumnList`'s content is only ever
compared (`=`) against `NVARCHAR` values later - it is never concatenated into a SQL
string, executed, or used to build an identifier directly. The only place caller text
from this parameter can influence the final dynamic SQL is by controlling *which
already-known-safe column name* gets included, not by injecting new text.

**[INFO] `@HasColumnFilter` computed once, reused**: Rather than repeating
`EXISTS (SELECT 1 FROM @RequestedColumns)` in every place that needs to know whether
filtering is active, it's computed once into a `BIT` variable immediately after
normalization. Phase 7 reads and, in one case, *rewrites* this variable (see below).

---

## New Section 2: Phase 7 Extension

```sql
-- Empty-match fallback
IF @HasColumnFilter = 1 AND NOT EXISTS (
    SELECT 1
    FROM tempdb.sys.columns c
    WHERE c.object_id = OBJECT_ID('tempdb..#Results')
      AND EXISTS (SELECT 1 FROM @RequestedColumns rc WHERE rc.ColumnName = c.name)
)
BEGIN
    SET @HasColumnFilter = 0;
END

IF @CompanyCount = 1 OR @HasColumnFilter = 1
BEGIN
    ...
    SELECT @ColumnsSql = @ColumnsSql
        + N',' + CHAR(13) + CHAR(10) + CHAR(9)
        + QUOTENAME(c.name)
        + CASE WHEN @CompanyCount = 1 THEN ISNULL((...label lookup...), N'') ELSE N'' END
    FROM tempdb.sys.columns c
    WHERE c.object_id = OBJECT_ID('tempdb..#Results')
      AND (
            @HasColumnFilter = 0
            OR EXISTS (SELECT 1 FROM @RequestedColumns rc WHERE rc.ColumnName = c.name)
          )
    ORDER BY c.column_id;
    ...
END
ELSE
BEGIN
    SELECT * FROM #Results;
END
```

**[✓] PASS - Pre-check before the main branch, not inside it**: The "does the
filter match anything?" check runs *before* the `IF @CompanyCount = 1 OR
@HasColumnFilter = 1` decision, so a `@ColumnList` that matches nothing correctly
falls through to the plain static `SELECT * FROM #Results` path when
`@CompanyCount <> 1` too - it doesn't get stuck in the dynamic branch just because it
was initially requested. This was verified by tracing all four combinations of
(`@CompanyCount = 1` or not) × (`@ColumnList` matches something, matches nothing, or
is absent):

| `@CompanyCount = 1`? | Column filter state | Branch taken | Behavior |
|---|---|---|---|
| No | No `@ColumnList` | `ELSE` (static) | All columns, no labels - unchanged from v3 |
| No | Matches ≥1 column | `IF` (dynamic) | Only matched columns, no labels |
| No | Matches 0 columns | `ELSE` (static) | Filter dropped; all columns, no labels |
| Yes | Any `@ColumnList` state | `IF` (dynamic) | Custom labels applied; columns filtered per the table above if `@HasColumnFilter` ends up 1, otherwise all columns with labels |

**[✓] PASS - Filtering and labeling are independent, composable conditions**: The
`WHERE` clause's column-inclusion test (`@HasColumnFilter = 0 OR EXISTS (...)`) and
the `SELECT` list's label-aliasing test (`CASE WHEN @CompanyCount = 1 THEN ... END`)
are separate `CASE`/`WHERE` conditions evaluated per column, not a single combined
flag - so a column can be included-with-a-label, included-without-a-label,
excluded-and-would-have-had-a-label, or excluded-and-wouldn't-have, correctly, in any
combination of `@CompanyCount` and `@ColumnList`.

**[✓] PASS - `QUOTENAME(c.name)` still applied to every included column**: Unchanged
from v2/v3 - every column name placed into the dynamic SQL string, whether or not
`@ColumnList` was involved in selecting it, is still escaped via `QUOTENAME()`.

**[INFO] No change to `#Results`' own column list**: `@ColumnList` only affects
Phase 7's *output* projection from `#Results`, not what Phase 5 computes into
`#Results` in the first place - all ~240 columns are still computed and materialized
into the temp table regardless of `@ColumnList`. See
`GVOverview_Performance_Analysis_Report_v4.md` for why this is (and isn't) a concern.

---

## Dependency Checklist

No new dependencies beyond what `v2/GVOverview_v2_SYNTAX_ANALYSIS.md` and
`v3/GVOverview_Performance_Analysis_Report_v3.md` already list.
`STRING_SPLIT` (used for `@ColumnList`, same as every other list parameter in this
procedure) and `tempdb.sys.columns` (already used for custom-field labeling since v2)
are the only system features Phase 2B/7's new code relies on.

---

## Summary

| Check | Result |
|---|---|
| New syntax introduced (table variable with `PRIMARY KEY`, per-item bracket stripping) | ✅ Valid, standard T-SQL |
| Sections unchanged vs. v3 | ✅ Confirmed via diff |
| All four (`@CompanyCount`, `@ColumnList`-match) branch combinations traced | ✅ Correct in each case |
| Injection surface | ✅ `@ColumnList` never concatenated into SQL text, only compared |
| Compiled against a live SQL Server instance | ⚠️ Not done in this environment - required before deployment |
