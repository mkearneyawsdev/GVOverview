-- =============================================
-- Supporting index for the EBillLatest computation (v1/v2's EBillLatest CTE;
-- the original procedure's unnamed "ebill" derived table)
-- =============================================
-- IMPORTANT - read this before running:
--
-- v3/GVOverview_Performance_Analysis_Report_v3.md originally proposed an index
-- keyed on (CaseId, [Approved Date] DESC) directly on dbo.Fact_EBill, on the
-- assumption that would let the ROW_NUMBER() OVER(PARTITION BY CaseId ORDER BY
-- [Approved Date] DESC) window function walk pre-sorted data and skip its Sort
-- operator entirely. Digging into the execution plan's actual column-level detail
-- (not just its cost summary) disproved that:
--
--   1. CaseId is NOT a column on dbo.Fact_EBill at all. The plan's Sort/OrderBy
--      shows the sort key is [Dim_Project].[CaseId] - it only becomes available
--      after Fact_EBill is joined to Dim_Project on Project_SK.
--   2. That join (and the others feeding the same Sort - to Dim_Company,
--      Dim_Beneficiary, and twice to Dim_User for manager/assistant lookups) are
--      all Hash Match joins in this plan. Hash Match does not preserve input row
--      order, so even a perfectly-ordered index on Fact_EBill would not survive
--      through to the point where the window function runs - the Sort operator
--      would very likely still be there.
--
-- So: this script does NOT eliminate the ~365-cost-unit Sort/Window Aggregate
-- (~32% of the query's total estimated cost) that the report flagged. That
-- requires a query/CTE-level fix - filtering EBillLatest down to the requested
-- company BEFORE computing ROW_NUMBER(), instead of windowing over the entire
-- warehouse's EBill history on every call (which is what all three versions -
-- original, v1, v2 - currently do; the CTE has no company filter of its own,
-- see the report for detail) - not something an index alone can fix.
--
-- What THIS index does do: right now, Fact_EBill is read for the EBillLatest
-- computation via a full Clustered Index Scan (cost 123.25, EstimateIO=121.9),
-- reading every column of every one of ~1.2M rows, because there's no filter
-- applied to Fact_EBill at that point (see above - the whole table is read
-- regardless of which company was requested). A narrow covering nonclustered
-- index containing only the columns EBillLatest actually needs lets the engine
-- scan that much smaller structure instead of the full wide clustered index -
-- same row count, meaningfully less data moved. It's a real, low-risk
-- improvement; it is just not the fix for the Sort.
--
-- Recommended next step beyond this script: revisit the EBillLatest CTE/subquery
-- to add a company filter before the ROW_NUMBER() computation (see
-- v3/GVOverview_Performance_Analysis_Report_v3.md, Issue #3 - corrected).
-- =============================================

-- Verify the index doesn't already exist before creating it
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Fact_EBill')
      AND name = 'IX_Fact_EBill_ProjectSK_ApprovedDate'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Fact_EBill_ProjectSK_ApprovedDate
        ON dbo.Fact_EBill (Project_SK, ApprovedDate DESC)
        INCLUDE (FeeStatus);
END
GO

-- =============================================
-- Verification: confirm the index was created
-- =============================================
SELECT
    i.name AS IndexName,
    i.type_desc,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.Fact_EBill')
  AND i.name = 'IX_Fact_EBill_ProjectSK_ApprovedDate'
GROUP BY i.name, i.type_desc;

-- =============================================
-- To actually measure whether this helped, capture a fresh ACTUAL execution plan
-- (not estimated) for the same query/parameters before and after this index, and
-- compare the Fact_EBill access cost and EstimateIO specifically. It will not
-- remove the Sort/Window Aggregate node - if that node disappears, something
-- other than this index (e.g. a statistics update, or a different join choice by
-- the optimizer) is responsible and should be investigated rather than assumed.
-- =============================================
