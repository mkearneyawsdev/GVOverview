# GVOverview_v2.sql - Syntax & Logic Analysis

**Companion to**: `../v1/GVOverview_v1_SYNTAX_ANALYSIS.md`
**Scope of this document**: Only the parts of `GVOverview_v2.sql` that differ from
`GVOverview_v1.sql`. Everything else (parameter handling, CTEs, JOINs, WHERE clause,
ORDER BY/OFFSET/FETCH, OPTION hint) was diffed byte-for-byte against v1 and is
unchanged - refer to the v1 document for that analysis.

---

## New Section 1: Phase 3B - Custom Field Label Resolution

```sql
DECLARE @CustomFieldLabels TABLE (
    SlotType   VARCHAR(10)   NOT NULL,
    SlotNumber INT           NOT NULL,
    FieldLabel NVARCHAR(100) NULL
);

IF @CompanyCount = 1
BEGIN
    DECLARE @Company_SK INT;
    SELECT TOP 1 @Company_SK = Id FROM @Company_SKs;

    INSERT INTO @CustomFieldLabels (SlotType, SlotNumber, FieldLabel)
    SELECT 'Profile', v.SlotNumber, NULLIF(LEFT(LTRIM(RTRIM(v.FieldLabel)), 100), '')
    FROM dbo.Dim_Company c
    CROSS APPLY (VALUES (1, c.CustomProfileField1), ..., (50, c.CustomProfileField50))
        v(SlotNumber, FieldLabel)
    WHERE c.Company_SK = @Company_SK;
    -- (identical INSERT repeated for 'Project' / CustomProjectFieldN)
END
```

**[✓] PASS - Table variable declaration**: Standard `DECLARE @x TABLE (...)` syntax,
valid since SQL Server 2000. `NVARCHAR(100)` is sized deliberately smaller than
`VARCHAR(4000)` on the source columns - see Note 1 below.

**[✓] PASS - `CROSS APPLY (VALUES ...)`**: This is the standard "unpivot via table
value constructor" pattern, valid since SQL Server 2008 (table value constructor) /
2005 (`CROSS APPLY`). It converts the 50 `CustomProfileFieldN` columns on a single
`Dim_Company` row into 50 rows of `(SlotNumber, FieldLabel)`. All 50 `VALUES` tuples
reference the same source row `c`, so this is a single-row-in, 50-rows-out expansion
per company - cheap regardless of table size, since it only ever runs against the one
row matched by `WHERE c.Company_SK = @Company_SK`.

**[✓] PASS - `NULLIF(LEFT(LTRIM(RTRIM(...)), 100), '')`**: Trims whitespace, truncates
to 100 characters, and converts an empty string to `NULL` so that "configured but
blank" and "not configured" are treated identically (both produce no label, so the
generic column name is kept in Phase 7).

**[INFO] Guarded by `IF @CompanyCount = 1`**: `@Company_SKs` and `@CompanyCount` are
both already populated by the unmodified Phase 3 logic before this block runs, so no
new dependency ordering was introduced.

### Note 1: Label length cap

The original procedure's `Dim_Company.CustomProfileFieldN` / `CustomProjectFieldN`
columns are presumed `VARCHAR`/`NVARCHAR` (exact declared length not verified against
a live schema in this environment - **flagged as a dependency to confirm before
deployment**, see `DEPLOYMENT_GUIDE_v2.md`). v2 caps the label at 100 characters via
`LEFT(...)` before it is ever used to build a column alias. This is a deliberate
safety margin, not a requirement of the original: SQL Server does not enforce the
128-character *identifier* length limit on a result-set column alias the way it does
on a persisted object name, but keeping aliases short avoids unwieldy column headers
in downstream reports/Excel exports.

---

## New Section 2: Custom Value Columns in the Main SELECT (Phase 5)

```sql
CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue1] AS NVARCHAR(4000))
     ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue1],
...  -- repeated for CustomProfileValue2..50 and CustomProjectValue1..50
```

**[✓] PASS - CASE expression with consistent branch types**: Both branches are
explicitly cast to `NVARCHAR(4000)`, avoiding SQL Server's implicit-type-inference
pitfalls when one branch is a bare `NULL` literal (a bare `NULL` has no type of its
own; without the explicit cast on both sides, the resulting column type is determined
solely by the non-NULL branch's source type, which is fine here, but the original
placeholder columns were explicitly typed `VARCHAR(4000)`, so v2 keeps that behavior
visible and explicit rather than implicit).

**[✓] PASS - Fully static**: This is not dynamic SQL. The `@CompanyCount = 1` check
is a normal runtime `CASE`, evaluated identically to any other filter condition in the
procedure - it does not prevent the query from having a single cached, static plan for
the *value-selection* portion of the query. (Dynamic SQL is only introduced later, in
Phase 7, for column *labeling* - which cannot be done any other way; see the
Performance Analysis Report for the cost/benefit tradeoff.)

**[INFO] Column count**: 100 additional columns added to the SELECT list. This is the
same total column count the original procedure could produce; v1 had reduced this to
0 by dropping the feature. No index or join changes were required to support these
columns since they read directly off `pb` (`rpt.vw_ProjectBeneficiary`), the same base
row already being read for every other column.

---

## New Section 3: `#Results` Temp Table

```sql
SELECT
    ... [full column list, including the 100 CASE-based custom columns] ...
INTO #Results
FROM rpt.vw_ProjectBeneficiary AS pb WITH (NOLOCK)
LEFT JOIN ...
WHERE ...
ORDER BY ...
OFFSET ... ROWS FETCH NEXT ... ROWS ONLY
OPTION (RECOMPILE, MAXDOP 4);
```

**[✓] PASS - `SELECT ... INTO` with `ORDER BY`/`OFFSET`/`FETCH`**: Valid T-SQL; the
`INTO` clause materializes the *already-paginated* result set (i.e., pagination is
applied before materialization, not after), so `#Results` only ever holds the page of
rows the caller asked for - not the full unfiltered result set.

**[✓] PASS - Local temp table lifetime and scope**: `#Results` is a session-scoped
local temp table. It is explicitly dropped at both entry (`IF OBJECT_ID('tempdb..#Results')
IS NOT NULL DROP TABLE #Results;`, guarding against a prior failed run leaving it
behind) and at the end of the procedure, after Phase 7 has read from it.

**[✓] PASS - Visibility from nested dynamic SQL**: A local temp table created in a
procedure's outer scope is visible to dynamic SQL run via `sp_executeSQL`/`EXEC` from
within that same procedure, because the dynamic batch executes in a nested scope that
can see the parent's temp tables (the reverse is not true). This is what makes Phase
7's `SELECT ... FROM #Results` inside the dynamic string valid without needing to pass
`#Results` in as a parameter.

**[WARNING - carried over from v1] `NOLOCK` / `READ UNCOMMITTED`**: Unchanged from v1;
already flagged there.

---

## New Section 4: Phase 7 - Targeted Dynamic Relabeling

```sql
IF @CompanyCount = 1
BEGIN
    DECLARE @ColumnsSql NVARCHAR(MAX) = N'';

    SELECT @ColumnsSql = @ColumnsSql
        + N',' + CHAR(13) + CHAR(10) + CHAR(9)
        + QUOTENAME(c.name)
        + ISNULL((
            SELECT TOP 1 N' AS ' + QUOTENAME(c.name + N':' + l.FieldLabel)
            FROM @CustomFieldLabels l
            WHERE l.FieldLabel IS NOT NULL
              AND c.name = N'Custom' + l.SlotType + N'Value' + CAST(l.SlotNumber AS NVARCHAR(2))
          ), N'')
    FROM tempdb.sys.columns c
    WHERE c.object_id = OBJECT_ID('tempdb..#Results')
    ORDER BY c.column_id;

    SET @ColumnsSql = STUFF(@ColumnsSql, 1, 1, N'');

    DECLARE @FinalSql NVARCHAR(MAX) = N'SELECT ' + @ColumnsSql + N' FROM #Results;';
    EXEC sp_executeSQL @FinalSql;
END
ELSE
BEGIN
    SELECT * FROM #Results;
END
```

**[✓] PASS - Variable concatenation with guaranteed order**: The classic
`SELECT @x = @x + ...` running-concatenation pattern is used, driven by a query with
an explicit `ORDER BY c.column_id`. This is the same technique the *original* 2017
procedure used for its `@CustomFieldSelect` string (and the same technique used
elsewhere in this file for building `@ColumnList`-style output in the original), so
v2 introduces no new idiom the codebase didn't already rely on.

**[✓] PASS - Metadata-driven column list, not a hardcoded copy of ~140 names**:
Rather than re-typing every non-custom column name into a second SQL string (a
duplication and drift risk), Phase 7 reads the actual column list back from
`tempdb.sys.columns` for `#Results`. Every column is passed through `QUOTENAME()`
unconditionally; only the up-to-100 columns whose name matches the
`Custom<Profile|Project>Value<N>` pattern get an additional `AS [...]` alias appended,
and only if `@CustomFieldLabels` has a non-NULL label for that exact slot. This means
Phase 7 self-adjusts if columns are ever added to or removed from the main SELECT
list, without needing to be edited in two places.

**[✓] PASS - `QUOTENAME()` on both sides of every dynamically-built identifier**:
- `QUOTENAME(c.name)` - the base column name, sourced from system metadata (not user
  input).
- `QUOTENAME(c.name + N':' + l.FieldLabel)` - the labeled alias. `l.FieldLabel`
  originates from `dbo.Dim_Company`, an internally-managed configuration table, not
  from any procedure parameter. `QUOTENAME()` doubles any `]` characters inside the
  wrapped string and encloses the whole thing in a single pair of brackets, which
  prevents a label such as `Foo]; DROP TABLE ...--` from breaking out of the alias and
  being interpreted as SQL. Even though the label source is trusted admin data rather
  than end-user input, this is defense in depth at negligible cost.

**[✓] PASS - `OBJECT_ID('tempdb..#Results')` for temp table metadata lookup**:
Standard, documented technique for resolving a local temp table's actual (uniquely
suffixed) object id in `tempdb` from within the same session.

**[✓] PASS - Conditional dynamic SQL, not unconditional**: The `ELSE` branch
(`SELECT * FROM #Results;`) is fully static and is what executes for the common case
(zero or multiple companies selected). `sp_executeSQL` is only invoked - and only ever
compiles a fresh ad-hoc plan - when exactly one company is selected.

**[INFO] `STUFF(@ColumnsSql, 1, 1, N'')`**: Removes the single leading comma produced
by the first iteration of the concatenation loop (the accumulator starts as `N''`,
so the first appended fragment begins with `,`). Standard idiom; equivalent to (and
simpler than) conditionally omitting the separator on the first row.

---

## Dependency Checklist (Additions to v1's List)

In addition to everything `GVOverview_v1_SYNTAX_ANALYSIS.md` already lists, v2
requires:

- [ ] `dbo.Dim_Company` exists and has `Company_SK` plus `CustomProfileField1..50`
      and `CustomProjectField1..50` (label) columns
- [ ] `rpt.vw_ProjectBeneficiary` (aliased `pb`) exposes `CustomProfileValue1..50` and
      `CustomProjectValue1..50` (value) columns - these were already part of the
      original view contract per `GVOverview.sql`, so this should already be
      satisfied, but has not been re-verified against a live schema in this pass
- [ ] `tempdb` has sufficient capacity/permissions for a session-scoped local temp
      table sized to one page of results (same order of magnitude as the existing
      `#`-prefixed temp table usage pattern, if any, elsewhere in this database)

---

## Summary

| Check | Result |
|---|---|
| New syntax introduced (`CROSS APPLY VALUES`, `SELECT INTO`, `tempdb.sys.columns`, `QUOTENAME`, `STUFF`) | ✅ Valid, standard T-SQL |
| Shared sections vs. v1 | ✅ Unchanged (verified via diff) |
| Dynamic SQL scope | ✅ Limited to column relabeling only, single-company case only |
| Injection surface | ✅ Mitigated via `QUOTENAME()`; label source is admin-managed, not caller input |
| Compiled against a live SQL Server instance | ⚠️ Not done in this environment - required before deployment |
