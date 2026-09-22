# GVOverview_v4 - Performance Impact Analysis: Reinstating `@ColumnList`

**Companion to**: `../v2/GVOverview_Performance_Analysis_Report_v2.md` (same
cost/benefit format, applied to a different feature) and
`../v3/GVOverview_Performance_Analysis_Report_v3.md` (the `EBillCaseFilter` change
this version also carries, unaffected by anything below).

---

## Summary

Unlike custom fields (v2) - which were pure added cost, since the original procedure
already computed them - `@ColumnList` (v4) is the first feature in this project with
a genuine potential **performance benefit** for the caller: requesting fewer columns
means less data serialized and sent back. The cost side is small and well-scoped: it
reuses Phase 7's existing dynamic-SQL mechanism rather than adding a new one, and
only activates it for calls that weren't already using it for a different reason.

---

## Cost 1: Phase 7's Dynamic Path Now Runs More Often

**What changed**: In v2/v3, Phase 7's `sp_executeSQL` step only ran when
`@CompanyCount = 1`. In v4, it also runs whenever `@ColumnList` matches at least one
real column - which can now include multi-company or all-companies calls that
previously took the cheap static `SELECT * FROM #Results` path.

**Impact**: The same characteristics already documented for this step in
`v2/GVOverview_Performance_Analysis_Report_v2.md` (Cost 3) apply here: an ad-hoc plan
compiled for the exact projection shape of that call, with plan-cache-space cost
proportional to how many distinct `@ColumnList` values are actually used in practice.
A caller that always requests the same fixed column subset gets one reusable ad-hoc
plan; a caller that varies the requested columns per call gets a new one each time
that particular combination is first seen.

**Verdict**: Same shape of cost as the existing custom-field labeling step, extended
to a new trigger condition. Not new in kind, just in when it fires.

---

## Cost 2: `#Results` Still Computes Every Column, Regardless of `@ColumnList`

**What changed**: Nothing, and that's the point of flagging it. `@ColumnList` only
filters what Phase 7 *projects out* of `#Results` - Phase 5 still computes and
materializes all ~240 columns into the temp table before Phase 7 ever looks at
`@ColumnList`.

**Why this wasn't "fixed"**: Filtering columns out of the *main* query's `SELECT`
list based on `@ColumnList` would require making Phase 5 itself dynamic (the same
"identifier can't be parameterized" constraint that motivates Phase 7's design in the
first place applies just as much to the main query's column list). Doing that would
mean rebuilding the entire filtering/join query as a dynamic-SQL string for every
distinct `@ColumnList` value - reintroducing exactly the large dynamic-SQL surface
area v1 removed, for the sake of skipping computation of a few `CASE`/column
expressions that are individually cheap (see v2's Performance report, Cost 1 - the
100 custom-field `CASE` columns were already assessed as low-impact per-row cost).

**Verdict**: A deliberate, documented scope boundary, not an oversight. The benefit
of `@ColumnList` in this design is entirely on the *output* side (less data
serialized/transferred back to the caller), not on reducing the work `#Results`
itself does to get computed.

---

## Benefit: Reduced Data Transfer

**What changed**: A caller that only needs, say, 10 of the ~240 available columns
now gets back a result set roughly 1/24th as wide (excluding whatever the driver's
per-column overhead is) as an unfiltered call - a real reduction in bytes serialized
by SQL Server, sent over the network, and deserialized/rendered by the caller.

**Where this matters most**: Any caller building a narrow view (e.g. a summary list
showing just Name, Company, and Case Status) previously had to either receive and
discard ~230 unwanted columns per row, or maintain a separate, narrower query outside
this procedure. `@ColumnList` removes that tradeoff.

**Verdict**: This is the actual point of the feature, and it's a genuine, real
benefit that scales with how many columns a given caller doesn't need - unlike
`@ColumnList`'s cost side (Phase 7 compilation), which is roughly fixed per distinct
request shape regardless of how few columns were kept.

---

## Net Assessment

| | v3 (no `@ColumnList`) | v4 (`@ColumnList` reinstated) |
|---|---|---|
| Dynamic SQL trigger conditions | `@CompanyCount = 1` only | `@CompanyCount = 1` **or** a matching `@ColumnList` |
| Work done to compute `#Results` | All ~240 columns, always | Unchanged - all ~240 columns, always |
| Data transferred back to caller | All requested columns | Only the requested subset, when supplied and valid |
| Callers unaffected | N/A | Any call without `@ColumnList` and with `@CompanyCount <> 1` - identical cost to v3 |

v4 is the first version in this project where a feature reinstatement has a plausible
net *positive* performance effect for at least some real callers (narrow-column
requests), traded against the same bounded, already-understood dynamic-SQL
compilation cost documented for custom fields in v2. As with every other estimate in
this project's documentation, this is reasoned from the query's structure, not
measured - see `DEPLOYMENT_GUIDE_v4.md` for the baseline-collection step that would
confirm it.
