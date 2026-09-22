# GVOverview_v2 - Performance Impact Analysis: Reinstating Custom Fields

**Companion to**: `../v1/GVOverview_Performance_Analysis_Report_v1.md`
**Scope**: Unlike the v1 report (which analyzed the *original* procedure), this report
analyzes the performance delta introduced by moving from `GVOverview_v1.sql` to
`GVOverview_v2.sql`. It assumes v1's analysis and fixes are already in place and does
not re-litigate them.

---

## Summary

Reinstating the custom-fields feature was not free - it reverses part of v1's "zero
dynamic SQL" achievement for one specific case. The design in v2 was chosen
specifically to keep that cost as small and as narrowly scoped as possible. Net
assessment: **negligible cost in the common case, small and bounded cost in the
single-company case**, in exchange for restoring a feature that was silently dropped
rather than intentionally deprecated.

---

## Cost 1: 100 Additional Columns in the Main SELECT

**What changed**: v1's main query selected roughly 140 columns. v2 adds 100 more
(`CASE WHEN @CompanyCount = 1 THEN ... ELSE NULL END` expressions reading
`pb.[CustomProfileValueN]` / `pb.[CustomProjectValueN]`).

**Impact**: All 100 additional columns read from `pb` (`rpt.vw_ProjectBeneficiary`),
the same base row every other column already reads from - no new JOIN, no new table
scan. The marginal cost is:
- Wider row size flowing through the query plan and into `#Results` (more bytes per
  row moved and materialized)
- 100 scalar `CASE` evaluations per row, which is CPU-cheap compared to the JOIN and
  filtering work already happening

**Verdict**: Low impact. This mirrors the cost the *original* pre-v1 procedure always
had for these same 100 columns - v2 does not add new cost beyond what already existed
before v1's refactor, it simply un-does v1's removal of it.

---

## Cost 2: Materializing Into `#Results` Instead of Returning Directly

**What changed**: v1 returned its result set directly from the main `SELECT`. v2
routes it through `SELECT ... INTO #Results` first.

**Impact**: This adds one tempdb write + one additional read (`SELECT * FROM
#Results` or the Phase 7 relabeling query) for every execution, regardless of company
selection. `#Results` only ever holds the *already-paginated* page of rows (pagination
is applied before the `INTO`), so this cost scales with `@Limit`/page size, not with
the size of the underlying filtered result set - it is bounded and small in typical
paginated-report usage (`@Limit` in the tens-to-low-thousands range), and would only
become material if the procedure were called with `@Limit = 0` (unbounded) against a
very large result set.

**Verdict**: Small, bounded, and proportional to page size rather than dataset size.
This is the one cost that applies on *every* call, not just single-company calls -
see Recommendation 1 below.

---

## Cost 3: The Phase 7 Dynamic Relabeling Step (Single-Company Case Only)

**What changed**: When exactly one company is selected, v2 runs one additional
`sp_executeSQL` call: a metadata lookup against `tempdb.sys.columns`, a string-building
loop over ~140-240 columns, and execution of the resulting dynamic `SELECT`.

**Impact**:
- This is the only genuinely "new" dynamic SQL in v2, and it is deliberately narrow:
  no JOINs, no WHERE clause, no user-input-driven branching - just a column list
  built from system metadata and label text.
- `sp_executeSQL` compiles an ad-hoc plan for this statement on every call where it
  runs, since the column list (and therefore the exact SQL text) can differ from one
  company to the next. This means no plan reuse across different companies for this
  specific step - each distinct combination of "which company's labels" produces a
  distinct ad-hoc plan, which will occupy plan cache space that a purely static query
  would not.
- The underlying data being selected (`#Results`) has already been fully computed by
  this point - Phase 7 is doing pure column projection/renaming over an
  already-materialized, already-paginated row set, not re-running any filtering or
  joins. Its cost is proportional to (row count in the page) × (column count), not to
  the size of the underlying tables.

**Verdict**: Bounded and isolated. This is the direct, unavoidable cost of the
label-in-column-name requirement (see "Why This Couldn't Be Fully Static" below). It
only applies to single-company report calls - the majority-case call pattern of "all
companies" or "multiple companies selected" pays none of this cost, since it takes
the plain static `SELECT * FROM #Results` branch instead.

---

## Why This Couldn't Be Fully Static

A SQL column alias is part of the query's *compiled shape*, not its data. Static SQL
can parameterize values, but not identifiers - there is no way to write
`SELECT x AS @SomeVariable` and have `@SomeVariable`'s runtime value become the actual
column name in the result set metadata. Since the feature's entire purpose is to
surface a company-configured label as the visible column name (not as a separate data
value), *some* form of dynamic SQL is structurally required for that one piece,
regardless of implementation approach. The v2 design's contribution is minimizing that
requirement to the smallest possible surface area (see Cost 3) rather than eliminating
it, which per the user's decision (see project conversation log) was the fidelity
priority over a fully-static redesign.

---

## Recommendations / Open Questions for Future Iteration

1. **Skip `#Results` entirely for the multi/zero-company path.** Currently *every*
   call pays Cost 2 (the temp table round-trip), even though only single-company calls
   need it (to let Phase 7 relabel afterward). A future optimization could branch
   earlier: multi/zero-company calls could `SELECT` directly without the `INTO
   #Results` indirection, matching v1's behavior exactly for that case, while only the
   single-company path uses the temp-table + relabel approach. This was not done in
   this pass to keep the main query's structure identical in both branches
   (simplicity/maintainability tradeoff); flagging it here as a follow-up if the
   temp-table overhead proves material under load testing.
2. **Measure real overhead before optimizing further.** All costs above are reasoned
   from the query plan shape, not measured - there is no SQL Server instance available
   in this environment to capture actual execution statistics. Phase 6 of
   `DEPLOYMENT_GUIDE_v2.md` covers collecting a real baseline; that data should confirm
   or override the qualitative assessment here before spending effort on
   Recommendation 1.
3. **`OPTION (RECOMPILE)` still applies to the main query** (unchanged from v1) and
   still has the same plan-caching tradeoff already flagged for v1 - not new to v2,
   but worth resolving together with any future performance work on this procedure.

---

## Net Assessment

| | v1 (no custom fields) | v2 (custom fields reinstated) |
|---|---|---|
| Dynamic SQL surface area | None | One short, isolated statement; only for single-company calls |
| Extra columns computed | 0 | 100 (cheap `CASE` over already-fetched row) |
| Extra materialization step | None | `#Results` temp table, bounded by page size |
| Plan cache behavior | One shape, `RECOMPILE`d per v1's existing hint | Same, plus one ad-hoc plan per distinct single-company relabeling call |
| Feature parity with original procedure | Partial (custom fields missing) | Full |

v2 trades a small, bounded, mostly single-company-scoped cost for restoring a feature
that has real business value and was removed as a side effect of the v1 refactor
rather than a deliberate decision to drop it.
