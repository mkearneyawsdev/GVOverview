USE [IMS_DataWarehouse]
GO

/****** Object:  StoredProcedure [bdp_rpt].[sp_GVOverview_v4]    Script Date: 9/22/2026 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		David Widmark
-- Create date: 12 Dec 2017
-- Description:	GV Overview report - all projects with all linked beneficiaries, joining immigration documents
-- REFACTORED:   9/15/2026 - v1 - Performance optimization - Removed dynamic SQL, added static query with runtime conditions
-- REFACTORED:   9/22/2026 - v2 - Reinstated the custom-fields feature that v1 dropped.
--
-- v2 Design Notes (Custom Fields):
--   All filtering, joins, CTEs and pagination remain static SQL exactly as in v1 (Issue #1 stays fixed
--   for the bulk of the query). The ONE piece of the original that is inherently impossible to express
--   in static SQL is carried over as a small, isolated dynamic-SQL step at the very end: a column alias
--   (e.g. [CustomProfileValue3:Visa Sponsor]) cannot be parameterized, only built as a string. That step
--   never touches user-supplied text; the label text comes only from dbo.Dim_Company (admin-managed
--   configuration data) and is passed through QUOTENAME() before being spliced into the SQL string.
--
--   Behavior (matches the original sp_GVOverview exactly):
--   - dbo.Dim_Company stores an optional display label per company for up to 50 "Profile" and 50
--     "Project" custom field slots (CustomProfileField1..50, CustomProjectField1..50).
--   - rpt.vw_ProjectBeneficiary stores the actual value per beneficiary/project in the matching
--     CustomProfileValue1..50 / CustomProjectValue1..50 columns.
--   - When exactly ONE company is selected via @CompanyIds, values are returned and the column name
--     carries that company's label for the slot, e.g. [CustomProfileValue3:Visa Sponsor]. Slots with
--     no label configured keep the generic column name.
--   - When zero companies or MORE THAN ONE company is selected, all 100 custom columns come back as
--     NULL with generic names - labels are company-specific and would be ambiguous/misleading if the
--     result set spans multiple companies. This matches the original procedure's behavior.
--
-- REFACTORED:   9/22/2026 - v3 - Fixes the EBillLatest performance issue identified by
--               execution-plan analysis (v3/GVOverview_Performance_Analysis_Report_v3.md,
--               Issue #3): EBillLatest computed ROW_NUMBER() over the entire warehouse's
--               EBill history on every call, regardless of @CompanyIds, because it was
--               never filtered by company at all - the company filter was only applied
--               later, against pb, after EBillLatest had already been fully computed.
--               That single unfiltered computation was estimated at ~32% of the whole
--               query's cost. v3 adds an EBillCaseFilter CTE that narrows EBillLatest to
--               only the CaseIds that could appear in this call's result (based on
--               @CompanyIds), before ROW_NUMBER() runs. This is logically safe: which
--               bill is "latest" for a case that already matches is unaffected by
--               excluding cases from OTHER companies, since a case belongs to exactly
--               one company. See that CTE's comment for the @AllCompanies = 1 case.
--
-- REFACTORED:   9/22/2026 - v4 - Reinstated the @ColumnList feature (return only the
--               caller-requested columns) that was silently dropped when v1 removed the
--               original's dynamic SQL wrapper. @ColumnList never worked in v1, v2, or v3
--               (it was declared but unused). Like the v2/v3 custom-field column
--               aliasing, which column comes back is a property of the query's compiled
--               shape, not its data - static SQL can't parameterize that. v4 extends the
--               same targeted, metadata-driven dynamic-SQL step already used for
--               custom-field labels (Phase 7) to also filter down to @ColumnList's
--               requested columns, rather than reintroducing dynamic SQL into the
--               filtering/join logic the way the original did.
--
--   Behavior:
--   - @ColumnList takes a comma-separated list of column names, with or without square
--     brackets (both "Company,Employee ID" and "[Company],[Employee ID]" work - each
--     item is normalized independently, unlike the original's all-or-nothing bracket
--     check).
--   - Requested names are matched against the actual result columns (case-insensitivity
--     follows the database's default collation); a name that doesn't match anything is
--     simply not included in the output - it does not cause an error, since the caller's
--     text is only ever compared against real column metadata, never spliced into SQL
--     directly.
--   - If none of the requested names match any real column, @ColumnList is ignored
--     entirely and every column is returned (rather than an empty result set) - this
--     favors returning something usable over guessing at what a completely-unmatched
--     request meant.
--   - NULL or empty @ColumnList (the default) returns every column, same as v1/v2/v3.
--   - For the 100 custom-field columns, @ColumnList matches on the BASE column name
--     (e.g. "CustomProfileValue3"), not the company-specific labeled alias (e.g.
--     "CustomProfileValue3:Visa Sponsor") - the label is only known once Phase 7 has
--     already decided which columns to include, so filtering happens before labeling.
--
-- Performance Improvements Carried Over From v1:
--   1. Eliminated dynamic SQL string concatenation for the main query body (Issue #1)
--   2. Consistent parameter validation logic (Issue #2)
--   3. Optimized EBill subquery with CTE, now also filtered by company before
--      windowing (Issue #3, corrected in v3 - see notes above)
--   4. Improved view join strategy (Issue #4)
--   5. (Superseded in v2 - custom field simplification from v1 is reverted; see notes above)
--   6. Optimized user filtering with efficient conditions (Issue #6)
--   7. Added deterministic pagination ordering (Issue #7)
--   8. Added OPTION hints for query optimization (Issue #8)
--   9. Pre-filtered LEFT JOINs (Issue #9)
--   10. Early parameter validation (Issue #17)
--   11. Resource governance with MAXDOP (Issue #22)
--
-- Change Log:
-- Update: 05/11/2022 - Added Application Location, Application Date and Other Application Location
-- Update: 1/17/2024 - ddcruz - DL-571 - added column [Location at time of filing application]
-- Update: 9/13/2024 - ddcruz - DL-725 - added columns for briefing, hours, scoring criteria
-- Update: 9/15/2026 - v1 - Refactored for performance: Static SQL instead of dynamic concatenation
-- Update: 9/22/2026 - v2 - Reinstated the custom-fields feature (Dim_Company-driven per-company labels)
-- Update: 9/22/2026 - v3 - Filter EBillLatest by company before windowing (execution-plan-driven fix)
-- Update: 9/22/2026 - v4 - Reinstated @ColumnList (return only requested columns)
-- =============================================

CREATE PROCEDURE [bdp_rpt].[sp_GVOverview_v4]
	@UserId INT = NULL
	, @ColumnList NVARCHAR(MAX) = NULL
	, @Limit INT = 0
	, @Offset INT = 0
	, @CountryCodes NVARCHAR(MAX) = N'ALL'
	, @Region NVARCHAR(MAX) = N'[All]'
	, @CompanyIds NVARCHAR(MAX) = N'-1'
	, @BALTeamUserIds NVARCHAR(MAX) = N'-1'
	, @ClosedProjects BIT = 0
	, @IncludeDependents BIT = 1
	, @ExcludeSubProjects BIT = 0
	, @ClosedProfiles BIT = 0
	, @Tracked BIT = 1
	, @CaseType NVARCHAR(MAX) = N'[All]'
	, @DebugMode BIT = 0

AS
BEGIN

	SET ARITHABORT OFF;
	SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

	-- =============================================
	-- PHASE 1: EARLY VALIDATION (Issue #17)
	-- Validate critical parameters at procedure entry
	-- =============================================
	IF @UserId IS NULL
	BEGIN
		RAISERROR('UserId parameter is required and cannot be NULL', 16, 1);
		RETURN;
	END

	-- Set session context for security
	EXEC sp_set_session_context @key=N'UserId', @value=@UserId;

	-- =============================================
	-- PHASE 2: NORMALIZE AND VALIDATE PARAMETERS (Issue #2)
	-- Consistent parameter validation with proper normalization
	-- =============================================
	DECLARE @CompanyIds_Normalized NVARCHAR(MAX) = UPPER(LTRIM(RTRIM(ISNULL(@CompanyIds, N'-1'))));
	DECLARE @CaseType_Normalized NVARCHAR(MAX) = UPPER(LTRIM(RTRIM(ISNULL(@CaseType, N'[ALL]'))));
	DECLARE @Region_Normalized NVARCHAR(MAX) = UPPER(LTRIM(RTRIM(ISNULL(@Region, N'[ALL]'))));
	DECLARE @CountryCodes_Normalized NVARCHAR(MAX) = UPPER(LTRIM(RTRIM(ISNULL(@CountryCodes, N'ALL'))));
	DECLARE @BALTeamUserIds_Normalized NVARCHAR(MAX) = LTRIM(RTRIM(ISNULL(@BALTeamUserIds, N'-1')));

	-- Determine if filters are "all" using single, consistent logic
	DECLARE @AllCompanies BIT = CASE WHEN @CompanyIds_Normalized IN (N'-1', N'ALL', N'[ALL]') THEN 1 ELSE 0 END;
	DECLARE @AllCaseTypes BIT = CASE WHEN @CaseType_Normalized IN (N'[ALL]', N'ALL') THEN 1 ELSE 0 END;
	DECLARE @AllCountries BIT = CASE WHEN @CountryCodes_Normalized = N'ALL' THEN 1 ELSE 0 END;
	DECLARE @AllRegions BIT = CASE WHEN @Region_Normalized IN (N'[ALL]', N'ALL') THEN 1 ELSE 0 END;
	DECLARE @AllUsers BIT = CASE WHEN @BALTeamUserIds_Normalized IN (N'-1', N'ALL') THEN 1 ELSE 0 END;

	-- =============================================
	-- PHASE 2B: NORMALIZE @ColumnList (NEW in v4)
	-- Splits the caller's comma-separated column list into a table variable, stripping
	-- any square brackets per-item (more robust than the original's all-or-nothing
	-- bracket check, which failed if brackets were only used on some items). This list
	-- is only ever compared against real column names from #Results' own metadata in
	-- Phase 7 - it is never concatenated directly into a SQL string, so it cannot be
	-- used to inject SQL via this parameter.
	-- =============================================
	DECLARE @RequestedColumns TABLE (ColumnName NVARCHAR(128) PRIMARY KEY);

	IF @ColumnList IS NOT NULL AND LEN(LTRIM(RTRIM(@ColumnList))) > 0
	BEGIN
		INSERT INTO @RequestedColumns (ColumnName)
		SELECT DISTINCT LTRIM(RTRIM(REPLACE(REPLACE([Value], '[', ''), ']', '')))
		FROM STRING_SPLIT(@ColumnList, ',')
		WHERE LEN(LTRIM(RTRIM(REPLACE(REPLACE([Value], '[', ''), ']', '')))) > 0;
	END

	DECLARE @HasColumnFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @RequestedColumns) THEN 1 ELSE 0 END;

	-- =============================================
	-- PHASE 3: BUILD FILTERED TABLE VARIABLES (Issue #14)
	-- Parse parameters into reusable table variables
	-- =============================================
	DECLARE @Company_SKs AS bdp_rpt_sup.IntIdList;
	DECLARE @BalTeam AS bdp_rpt_sup.IntIdList;
	DECLARE @Countries AS bdp_rpt_sup.StringIdList;
	DECLARE @Regions AS bdp_rpt_sup.StringIdList;
	DECLARE @CaseTypes AS bdp_rpt_sup.StringIdList;
	DECLARE @CompanyCount INT = 0;

	-- Populate company filter
	IF @AllCompanies = 0
	BEGIN
		INSERT INTO @Company_SKs
		SELECT CAST([Value] AS BIGINT)
		FROM STRING_SPLIT(@CompanyIds_Normalized, ',')
		WHERE [Value] IS NOT NULL AND LEN([Value]) > 0;

		SELECT @CompanyCount = @@ROWCOUNT;
	END

	-- Populate user filter
	IF @AllUsers = 0
	BEGIN
		INSERT INTO @BalTeam
		SELECT CAST([Value] AS INT)
		FROM STRING_SPLIT(@BALTeamUserIds_Normalized, ',')
		WHERE [Value] IS NOT NULL AND LEN([Value]) > 0;
	END

	-- Populate country filter
	IF @AllCountries = 0
	BEGIN
		INSERT INTO @Countries
		SELECT LTRIM(RTRIM([Value]))
		FROM STRING_SPLIT(@CountryCodes_Normalized, ',')
		WHERE [Value] IS NOT NULL AND LEN([Value]) > 0;
	END

	-- Populate region filter
	IF @AllRegions = 0
	BEGIN
		INSERT INTO @Regions
		SELECT LTRIM(RTRIM([Value]))
		FROM STRING_SPLIT(@Region_Normalized, ',')
		WHERE [Value] IS NOT NULL AND LEN([Value]) > 0;
	END

	-- Populate case type filter
	IF @AllCaseTypes = 0
	BEGIN
		INSERT INTO @CaseTypes
		SELECT LTRIM(RTRIM([Value]))
		FROM STRING_SPLIT(@CaseType_Normalized, ',')
		WHERE [Value] IS NOT NULL AND LEN([Value]) > 0;
	END

	-- =============================================
	-- PHASE 3B: CUSTOM FIELD LABEL RESOLUTION (NEW in v2)
	-- Reinstates the original custom-fields feature. Only resolved when exactly one
	-- company is selected (@CompanyCount = 1) - see design notes at the top of this file.
	-- =============================================
	DECLARE @CustomFieldLabels TABLE (
		SlotType   VARCHAR(10)   NOT NULL,  -- 'Profile' or 'Project'
		SlotNumber INT           NOT NULL,  -- 1..50
		FieldLabel NVARCHAR(100) NULL       -- company-configured label for this slot, or NULL if unused
	);

	IF @CompanyCount = 1
	BEGIN
		DECLARE @Company_SK INT;
		SELECT TOP 1 @Company_SK = Id FROM @Company_SKs;

		INSERT INTO @CustomFieldLabels (SlotType, SlotNumber, FieldLabel)
		SELECT 'Profile', v.SlotNumber, NULLIF(LEFT(LTRIM(RTRIM(v.FieldLabel)), 100), '')
		FROM dbo.Dim_Company c
		CROSS APPLY (VALUES
			(1, c.CustomProfileField1), (2, c.CustomProfileField2), (3, c.CustomProfileField3), (4, c.CustomProfileField4), (5, c.CustomProfileField5),
			(6, c.CustomProfileField6), (7, c.CustomProfileField7), (8, c.CustomProfileField8), (9, c.CustomProfileField9), (10, c.CustomProfileField10),
			(11, c.CustomProfileField11), (12, c.CustomProfileField12), (13, c.CustomProfileField13), (14, c.CustomProfileField14), (15, c.CustomProfileField15),
			(16, c.CustomProfileField16), (17, c.CustomProfileField17), (18, c.CustomProfileField18), (19, c.CustomProfileField19), (20, c.CustomProfileField20),
			(21, c.CustomProfileField21), (22, c.CustomProfileField22), (23, c.CustomProfileField23), (24, c.CustomProfileField24), (25, c.CustomProfileField25),
			(26, c.CustomProfileField26), (27, c.CustomProfileField27), (28, c.CustomProfileField28), (29, c.CustomProfileField29), (30, c.CustomProfileField30),
			(31, c.CustomProfileField31), (32, c.CustomProfileField32), (33, c.CustomProfileField33), (34, c.CustomProfileField34), (35, c.CustomProfileField35),
			(36, c.CustomProfileField36), (37, c.CustomProfileField37), (38, c.CustomProfileField38), (39, c.CustomProfileField39), (40, c.CustomProfileField40),
			(41, c.CustomProfileField41), (42, c.CustomProfileField42), (43, c.CustomProfileField43), (44, c.CustomProfileField44), (45, c.CustomProfileField45),
			(46, c.CustomProfileField46), (47, c.CustomProfileField47), (48, c.CustomProfileField48), (49, c.CustomProfileField49), (50, c.CustomProfileField50)
		) v(SlotNumber, FieldLabel)
		WHERE c.Company_SK = @Company_SK;

		INSERT INTO @CustomFieldLabels (SlotType, SlotNumber, FieldLabel)
		SELECT 'Project', v.SlotNumber, NULLIF(LEFT(LTRIM(RTRIM(v.FieldLabel)), 100), '')
		FROM dbo.Dim_Company c
		CROSS APPLY (VALUES
			(1, c.CustomProjectField1), (2, c.CustomProjectField2), (3, c.CustomProjectField3), (4, c.CustomProjectField4), (5, c.CustomProjectField5),
			(6, c.CustomProjectField6), (7, c.CustomProjectField7), (8, c.CustomProjectField8), (9, c.CustomProjectField9), (10, c.CustomProjectField10),
			(11, c.CustomProjectField11), (12, c.CustomProjectField12), (13, c.CustomProjectField13), (14, c.CustomProjectField14), (15, c.CustomProjectField15),
			(16, c.CustomProjectField16), (17, c.CustomProjectField17), (18, c.CustomProjectField18), (19, c.CustomProjectField19), (20, c.CustomProjectField20),
			(21, c.CustomProjectField21), (22, c.CustomProjectField22), (23, c.CustomProjectField23), (24, c.CustomProjectField24), (25, c.CustomProjectField25),
			(26, c.CustomProjectField26), (27, c.CustomProjectField27), (28, c.CustomProjectField28), (29, c.CustomProjectField29), (30, c.CustomProjectField30),
			(31, c.CustomProjectField31), (32, c.CustomProjectField32), (33, c.CustomProjectField33), (34, c.CustomProjectField34), (35, c.CustomProjectField35),
			(36, c.CustomProjectField36), (37, c.CustomProjectField37), (38, c.CustomProjectField38), (39, c.CustomProjectField39), (40, c.CustomProjectField40),
			(41, c.CustomProjectField41), (42, c.CustomProjectField42), (43, c.CustomProjectField43), (44, c.CustomProjectField44), (45, c.CustomProjectField45),
			(46, c.CustomProjectField46), (47, c.CustomProjectField47), (48, c.CustomProjectField48), (49, c.CustomProjectField49), (50, c.CustomProjectField50)
		) v(SlotNumber, FieldLabel)
		WHERE c.Company_SK = @Company_SK;
	END

	-- =============================================
	-- PHASE 4: PREPARE OPTIMIZED DATA STRUCTURES (Issues #3, #4, #9)
	-- Build CTEs and temp structures with pre-filtering
	-- =============================================

	-- CTE 0: Case scope for EBillLatest (NEW in v3 - see header notes)
	-- Narrows the ROW_NUMBER() computation below to only the CaseIds that could
	-- appear in this call's result set, instead of windowing over the entire
	-- warehouse's EBill history on every execution. Filtering by company here is
	-- safe: it does not change which bill is "latest" for any case that still
	-- matches, since a case belongs to exactly one company.
	--
	-- When @AllCompanies = 1 (the default / "ALL companies" case), this CTE still
	-- has to enumerate every CaseId from rpt.vw_ProjectBeneficiary - there is no
	-- company-level filter to apply. The "@AllCompanies = 1 OR EXISTS (...)" guard
	-- on EBillLatest below is written so that, under this procedure's
	-- OPTION (RECOMPILE) - which lets SQL Server substitute the actual runtime
	-- value of @AllCompanies at compile time - the optimizer has the opportunity to
	-- recognize the EXISTS branch as dead code and skip evaluating this CTE
	-- entirely for that case. That optimization is not guaranteed by the SQL
	-- Server documentation; verify it with a fresh execution plan (see
	-- v3/GVOverview_Performance_Analysis_Report_v3.md) rather than assuming it.
	WITH EBillCaseFilter AS (
		SELECT DISTINCT company_sk, CaseId
		FROM rpt.vw_ProjectBeneficiary
		WHERE BeneficiaryIncludedInProject = 1
	),

	-- CTE 1: Optimized EBill data with deduplication (Issue #3, corrected in v3)
	-- Only get the latest bill per case with most recent approved date, and only
	-- for cases that pass this call's company filter (see EBillCaseFilter above).
	EBillLatest AS (
		SELECT
			eb.CaseId,
			CASE WHEN eb.[Fee Status] = 'PENDING_APPROVAL' THEN 'YES' ELSE 'NO' END [Bills Pending Approval],
			ROW_NUMBER() OVER(PARTITION BY eb.CaseId ORDER BY eb.[Approved Date] DESC) RN
		FROM rpt.vw_EBill eb
		WHERE eb.CaseId IS NOT NULL
		  AND (
				@AllCompanies = 1
				OR EXISTS (
					SELECT 1 FROM EBillCaseFilter fc
					WHERE fc.CaseId = eb.CaseId
					  AND fc.company_sk IN (SELECT Id FROM @Company_SKs)
				)
		  )
	),

	-- CTE 2: Deduplicated Project data with latest records (Issue #9)
	ProjectData AS (
		SELECT DISTINCT
			p.CaseId,
			p.[Application Location],
			p.[Application Date],
			p.[Other Application Location],
			p.[Project Job Description],
			p.[LMT Advertising Expiry],
			p.[IPA Expiry],
			p.[PEA Expiry Pre-Entry Approval],
			p.[COE Expiry],
			p.[DGIM Approval Expiry],
			p.[EP/DP/PVP Approval Letter Expiry]
		FROM rpt.vw_Project p
		WHERE p.CaseId IS NOT NULL
	),

	-- CTE 3: Deduplicated ProcessDetail data (Issue #9)
	ProcessDetailData AS (
		SELECT
			pd.CaseId,
			pd.[ANZSCOOccupation],
			pd.[Locationattimeoffilingapplication],
			pd.[BriefingCallDate],
			pd.[WeeklyWorkingHours],
			pd.[ExemptfromCOMPASSassessment],
			pd.[Eligiblefora5yearEPforexperiencedtechprofessionalswithskillsinshortage],
			pd.[C1Salary],
			pd.[C2Qualifications],
			pd.[C3Diversity],
			pd.[C4SupportforLocalEmployment],
			pd.[C5SkillsBonus],
			pd.[C6StrategicEconomicPrioritiesBonus],
			pd.[ShortageOccupationList],
			pd.[DateEducationCheckInitiated],
			pd.[DateEducationCheckCompleted],
			pd.[DocumentDraftCompleted],
			pd.[DecisionDueEmployee],
			pd.[DecisionDueDependents],
			ROW_NUMBER() OVER(PARTITION BY pd.CaseId ORDER BY pd.DateCreated DESC) RN
		FROM dbo.dim_ProcessDetail pd
		WHERE pd.CaseId IS NOT NULL
	)

	-- =============================================
	-- PHASE 5: MAIN QUERY - STATIC SQL (Issue #1)
	-- All conditions evaluated at runtime, no string concatenation.
	-- Result lands in #Results (paginated) so Phase 6 can add custom-field labels
	-- without re-running the joins/filters.
	-- =============================================
	IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;

	SELECT
		pb.[Company],
		pb.[Employee ID],
		pb.[Principal Full Name Last First Middle],
		pb.[Full Name Last First Middle],
		pb.[First Name],
		pb.[Last Name],
		pb.[Entity] [Employing Entity],
		pb.[Relationship],
		pb.[Pre-Hire ID],
		pb.[Case Region],
		pb.[Case Country],
		pb.[Case City],
		pb.[Origin Country],
		pb.[Origin City],
		pb.[Case Type],
		pb.[Case Sub-Type],
		pb.[Case Type Category],
		pb.[Project Matter Number],
		pb.[Parent CaseId],
		CASE WHEN pb.[Parent CaseId] IS NULL THEN 0 ELSE 1 END AS [Is Sub-Project?],
		pb.[Parent Project Matter Number],
		pb.[Case Assignment Type],
		pb.[Open],
		pb.[Initial Contact],
		pb.[Initial Info Received],
		pb.[Docs Out],
		pb.[Docs Out to NP],
		pb.[All Signed Docs Received],
		pb.[Actioned for Filing],
		pb.[Filed],
		pb.[Decision],
		pb.[Denied],
		pb.[Close],
		pb.[Current Stage],
		pb.[Last Milestone],
		pb.[Last Milestone Complete Date],
		pb.[Next Milestone],
		pb.[Next Milestone Start Date],
		pb.[Next Milestone Due Date],
		pb.[Last Task],
		pb.[Last Task Start Date],
		pb.[Last Task Completion Date],
		pb.[Next Task],
		pb.[Next Task Start Date],
		pb.[Next Task Due Date],
		pb.[Last Report Note],
		pb.[Last Report Note Date],
		pb.[Government Case Number - Case Overview],
		sd.[Doc Type],
		sd.[Is Tracking],
		sd.[Classification],
		sd.[Expiration Date],
		sd.[Begin Date],
		sd.[End Date],
		sd.[Maximum Date],
		sd.[Authorized Work City],
		sd.[Number Of Entries],
		sd.Notes,
		sd.[Government Case Number – Immigration Documents],
		pb.[Dependent Only],
		pb.[Included Dependents],
		pb.[Original Hire Date],
		pb.[Start Date] [Assignment Start Date],
		pb.[Estimated Travel Date],
		pb.[Estimated Start Date],
		pb.[End Date] [Assignment End Date],
		pb.[Rehire Date],
		pb.[Reason For Change],
		pb.[BAL Manager Full Name Last First] AS [Project Manager Full Name Last First],
		pb.[BAL Manager Email] AS [Project Manager Email],
		pb.[BAL Manager Home Office Loc] AS [Project Manager Home Office Loc],
		pb.[BAL Assistant Full Name Last First] AS [Project Assistant Full Name Last First],
		pb.[BAL Assistant Email] AS [Project Assistant Email],
		pb.[BAL Assistant Home Office Loc] AS [Project Assistant Home Office Loc],
		pb.[BAL Manager 2 Full Name Last First] AS [Project Manager 2 Full Name Last First],
		pb.[BAL Manager 2 Email] AS [Project Manager 2 Email],
		pb.[BAL Assistant 2 Full Name Last First] AS [Project Assistant 2 Full Name Last First],
		pb.[BAL Assistant 2 Email] AS [Project Assistant 2 Email],
		pb.[BAL Manager 3 Full Name Last First] AS [Project Manager 3 Full Name Last First],
		pb.[BAL Manager 3 Email] AS [Project Manager 3 Email],
		pb.[BAL Assistant 3 Full Name Last First] AS [Project Assistant 3 Full Name Last First],
		pb.[BAL Assistant 3 Email] AS [Project Assistant 3 Email],
		ebill.[Bills Pending Approval],
		pb.[Bill Approved Date],
		pb.[No Bill],
		pb.[NP Company],
		pb.[NP Full Name Last First],
		pb.[NP Email],
		pb.[HR Full Name Last First],
		pb.[HR Email],
		pb.[HR Phone],
		pb.[Signer Full Name Last First],
		pb.[Signer Email],
		pb.[Signer Phone],
		pb.[Manager Full Name Last First],
		pb.[Manager Email],
		pb.[Manager Phone],
		pb.[Project Entity],
		pb.[Business Unit],
		pb.[Nationality 1],
		pb.[Nationality 2],
		pb.[Nationality 3],
		pb.[COB],
		pb.[DOB],
		pb.[Passport 1 Country],
		pb.[Passport 1 IssuedCountry],
		pb.[Passport 1 Number],
		pb.[Passport 1 IssuedDate],
		pb.[Passport 1 ExpirationDate],
		pb.[Passport 2 Country],
		pb.[Passport 2 IssuedCountry],
		pb.[Passport 2 Number],
		pb.[Passport 2 IssuedDate],
		pb.[Passport 2 ExpirationDate],
		pb.[Email],
		pb.[Phone Number],
		pb.[Project Job Position],
		pb.[Project Job Level],
		pb.[Project Job Code],
		pd_main.[Project Job Description],
		pb.[Project Salary],
		pb.[Project Salary Currency],
		pb.[Project Frequency of Salary],
		pb.[Project Work Location 1 CityCountry] [Project Work Location 1],
        pb.[Project Work Location 2 CityCountry] [Project Work Location 2],
		pb.[Job Position] AS [Profile Job Position],
		pb.[Job Level] AS [Profile Job Level],
		pb.[Job Code] AS [Profile Job Code],
		pb.[Base Salary] AS [Profile Base Salary],
		pb.[Currency] AS [Profile Salary Currency],
		pb.[Frequency of Salary] AS [Profile Frequency of Salary],
		COALESCE(pb.[Work City] + ' - ' + pb.[Work Country], pb.[Work City], pb.[Work Country]) [Profile Work Location],
		COALESCE(pb.[Work 2nd City] + ' - ' + pb.[Work 2nd Country], pb.[Work 2nd City], pb.[Work 2nd Country]) [Profile Work Location 2],
		ISNULL(pb.[Residence Address Line 1] ,'') + ISNULL(' ' + pb.[Residence Address Line 2],'') + ISNULL(' ' + pb.[Residence Suite], '') + ISNULL(' ' + pb.[Residence City], '') + ISNULL(' ' + pb.[Residence State], '') + ISNULL(' ' + pb.[Residence Postal Code], '') + ISNULL(' ' + pb.[Residence Country], '') AS [Current Residence Address],
		pb.[Termination Date],
		pb.[Field of Study 1],
		pb.[Education Institution 1],
		pb.[Degree Received 1],
		pb.[Field of Study 2],
		pb.[Education Institution 2],
		pb.[Degree Received 2],
		pb.[Field of Study 3],
		pb.[Education Institution 3],
		pb.[Degree Received 3],
		pb.[User Name],
		pb.[User Login Method],
		CASE WHEN pb.[User Login Method]='Internal' AND pb.[WebAccess]=1 AND pb.[IsActive]=1 THEN 'Web Access Active'
			WHEN pb.[User Login Method]='Internal' AND pb.[WebAccess]=1 AND pb.[IsActive]=0 THEN 'Web Access Inactive'
			WHEN pb.[User Login Method]='Internal' AND pb.[WebAccess]=0 THEN 'No Web Access'
			WHEN pb.[User Login Method] IN ('SSO','GOAUTH') AND pb.[WebAccess]=1 THEN 'Web Access Active'
			ELSE 'No Web Access' END AS [Web Access],
		CASE WHEN pb.[User Login Method]='Internal' THEN 'Username/Password' ELSE pb.[User Login Method] END AS [Access Type],
		pb.[All Info Recd] [All Info Received],
		pb.[Is Principal],
		pb.[Residence Appointment Date],
		pb.[IRP Card Received by Service Provider?],
		pd_main.[LMT Advertising Expiry],
		pd_main.[IPA Expiry],
		pd_main.[PEA Expiry Pre-Entry Approval],
		pd_main.[COE Expiry],
        pd_main.[DGIM Approval Expiry],
        pd_main.[EP/DP/PVP Approval Letter Expiry],
		pb.[company_sk],
		pb.[project_SK],
		pb.[case country code],
		pb.[Contact Active],
		CASE WHEN pb.[Contact Active] = 1 THEN 'Yes' ELSE 'No' END AS [Open Profile (Yes/No)],
        pb.[BALManagerUserId],
        pb.[BALAssistantUserId],
        pb.[BALManager2UserId],
        pb.[BALAssistant2UserId],
        pb.[BALManager3UserId],
        pb.[BALAssistant3UserId],
		pd_main.[Application Location],
		pd_main.[Application Date],
		pd_main.[Other Application Location],
		pdd.[ANZSCOOccupation] AS [ANZSCO Occupation],
		pdd.[Locationattimeoffilingapplication] AS [Location at time of filing application],
		pdd.[BriefingCallDate] AS [Briefing Call Date],
		pdd.[WeeklyWorkingHours] AS [Weekly Working Hours],
        pdd.[ExemptfromCOMPASSassessment] AS [Exempt from COMPASS assessment?],
        pdd.[Eligiblefora5yearEPforexperiencedtechprofessionalswithskillsinshortage] AS [Eligible for a 5 year EP for experienced tech professionals with skills in shortage?],
        pdd.[C1Salary] AS [C1 – Salary],
        pdd.[C2Qualifications] AS [C2 – Qualifications],
        pdd.[C3Diversity] AS [C3 – Diversity],
        pdd.[C4SupportforLocalEmployment] AS [C4 – Support for Local Employment],
        pdd.[C5SkillsBonus] AS [C5 – Skills Bonus],
        pdd.[C6StrategicEconomicPrioritiesBonus] AS [C6 – Strategic Economic Priorities Bonus],
        pdd.[ShortageOccupationList] AS [Shortage Occupation List (SOL)?],
        pdd.[DateEducationCheckInitiated] AS [Date Education Check Initiated],
        pdd.[DateEducationCheckCompleted] AS [Date Education Check Completed],
		pdd.[DocumentDraftCompleted] AS [Document Draft Completed],
		pdd.[DecisionDueEmployee] AS [Decision Due - Employee],
        pdd.[DecisionDueDependents] AS [Decision Due - Dependent(s)],

		-- Custom Profile fields (reinstated in v2, Issue: original custom-fields feature)
		-- Value is suppressed (NULL) unless exactly one company is selected via @CompanyIds,
		-- since a per-company field label can only be attached unambiguously in that case.
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue1] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue1],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue2] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue2],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue3] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue3],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue4] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue4],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue5] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue5],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue6] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue6],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue7] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue7],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue8] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue8],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue9] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue9],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue10] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue10],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue11] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue11],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue12] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue12],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue13] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue13],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue14] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue14],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue15] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue15],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue16] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue16],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue17] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue17],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue18] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue18],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue19] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue19],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue20] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue20],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue21] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue21],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue22] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue22],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue23] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue23],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue24] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue24],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue25] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue25],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue26] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue26],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue27] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue27],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue28] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue28],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue29] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue29],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue30] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue30],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue31] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue31],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue32] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue32],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue33] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue33],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue34] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue34],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue35] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue35],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue36] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue36],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue37] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue37],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue38] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue38],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue39] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue39],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue40] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue40],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue41] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue41],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue42] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue42],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue43] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue43],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue44] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue44],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue45] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue45],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue46] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue46],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue47] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue47],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue48] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue48],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue49] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue49],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProfileValue50] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProfileValue50],

		-- Custom Project fields (reinstated in v2)
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue1] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue1],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue2] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue2],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue3] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue3],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue4] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue4],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue5] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue5],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue6] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue6],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue7] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue7],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue8] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue8],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue9] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue9],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue10] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue10],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue11] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue11],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue12] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue12],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue13] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue13],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue14] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue14],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue15] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue15],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue16] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue16],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue17] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue17],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue18] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue18],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue19] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue19],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue20] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue20],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue21] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue21],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue22] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue22],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue23] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue23],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue24] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue24],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue25] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue25],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue26] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue26],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue27] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue27],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue28] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue28],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue29] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue29],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue30] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue30],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue31] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue31],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue32] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue32],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue33] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue33],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue34] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue34],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue35] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue35],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue36] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue36],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue37] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue37],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue38] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue38],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue39] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue39],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue40] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue40],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue41] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue41],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue42] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue42],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue43] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue43],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue44] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue44],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue45] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue45],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue46] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue46],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue47] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue47],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue48] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue48],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue49] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue49],
		CASE WHEN @CompanyCount = 1 THEN CAST(pb.[CustomProjectValue50] AS NVARCHAR(4000)) ELSE CAST(NULL AS NVARCHAR(4000)) END AS [CustomProjectValue50]

	INTO #Results

	FROM rpt.vw_ProjectBeneficiary AS pb WITH (NOLOCK)

	-- LEFT JOIN to Status Docs with early filtering (Issue #9)
	LEFT JOIN rpt.vw_StatusDocs sd WITH (NOLOCK)
		ON pb.Beneficiary_SK = sd.Beneficiary_SK
		AND pb.[Country Code] = sd.[Country Code]
		AND sd.[Is Document] = 1
		AND (@Tracked = 1 OR sd.[Is Tracking] = 1)

	-- LEFT JOIN to EBill with latest deduplication (Issue #3)
	LEFT JOIN EBillLatest ebill
		ON pb.CaseId = ebill.CaseId
		AND ebill.RN = 1

	-- LEFT JOIN to Project data with deduplication (Issue #9)
	LEFT JOIN ProjectData pd_main
		ON pb.CaseId = pd_main.CaseId

	-- LEFT JOIN to ProcessDetail data with deduplication (Issue #9)
	LEFT JOIN ProcessDetailData pdd
		ON pb.CaseId = pdd.CaseId
		AND pdd.RN = 1

	-- =============================================
	-- RUNTIME FILTERING CONDITIONS (Issue #1, #6)
	-- All WHERE conditions evaluated at runtime, not built as strings
	-- =============================================
	WHERE
		pb.[BeneficiaryIncludedInProject] = 1
		AND (
			-- Company filter
			@AllCompanies = 1
			OR pb.company_sk IN (SELECT Id FROM @Company_SKs)
		)
		AND (
			-- Country filter
			@AllCountries = 1
			OR pb.[case country code] IN (SELECT Id FROM @Countries)
		)
		AND (
			-- Region filter
			@AllRegions = 1
			OR pb.[Case Region] IN (SELECT Id FROM @Regions)
		)
		AND (
			-- Closed projects filter
			@ClosedProjects = 1
			OR pb.[Close] IS NULL
		)
		AND (
			-- Closed profiles filter
			@ClosedProfiles = 1
			OR pb.[Contact Active] = 1
		)
		AND (
			-- Case type filter
			@AllCaseTypes = 1
			OR pb.[Case Type] IN (SELECT Id FROM @CaseTypes)
		)
		AND (
			-- User filter (Issue #6) - Optimized user assignment check
			@AllUsers = 1
			OR pb.[BALManagerUserId] IN (SELECT Id FROM @BalTeam)
			OR pb.[BALAssistantUserId] IN (SELECT Id FROM @BalTeam)
			OR pb.[BALManager2UserId] IN (SELECT Id FROM @BalTeam)
			OR pb.[BALAssistant2UserId] IN (SELECT Id FROM @BalTeam)
			OR pb.[BALManager3UserId] IN (SELECT Id FROM @BalTeam)
			OR pb.[BALAssistant3UserId] IN (SELECT Id FROM @BalTeam)
		)
		AND (
			-- Dependent filter
			@IncludeDependents = 1
			OR pb.[Is Principal] = 1
		)
		AND (
			-- Sub-project filter
			@ExcludeSubProjects = 0
			OR pb.[Parent CaseId] IS NULL
		)

	-- =============================================
	-- PHASE 6a: PAGINATION WITH DETERMINISTIC ORDERING (Issue #7)
	-- Multiple sort keys ensure consistent pagination
	-- =============================================
	ORDER BY
		pb.[Project Matter Number] ASC,
		pb.[Beneficiary_SK] ASC,
		pb.[CaseId] ASC,
		pb.[Full Name Last First Middle] ASC

	OFFSET ISNULL(@Offset, 0) ROWS

	-- FETCH NEXT with proper boundary handling
	FETCH NEXT CASE
		WHEN @Limit <= 0 THEN 9999999  -- No limit, return all
		ELSE @Limit
	END ROWS ONLY

	-- =============================================
	-- PHASE 6b: QUERY OPTIMIZATION HINTS (Issue #8)
	-- Provides hints for query optimizer and resource governance
	-- =============================================
	OPTION (RECOMPILE, MAXDOP 4);  -- Recompile for parameter variation, limit parallelism to 4 threads

	-- =============================================
	-- PHASE 7: OUTPUT - relabel custom-field columns and/or apply @ColumnList (v2 + v4)
	-- The dynamic-SQL path below only runs when it actually has work to do: either
	-- exactly one company was selected (custom-field labels need building), or
	-- @ColumnList named at least one column that matched. Otherwise the full,
	-- unfiltered result set is returned via plain static SQL, same as v1/v2/v3.
	--
	-- Custom-field labels come exclusively from dbo.Dim_Company, and the @ColumnList
	-- filter is only ever compared against real column names from #Results' own
	-- metadata (tempdb.sys.columns) - neither is ever concatenated raw from caller
	-- input, and both are passed through QUOTENAME() before being placed in the SQL
	-- string, so this cannot be used to inject arbitrary SQL via report parameters.
	-- =============================================

	-- If @ColumnList was provided but matches none of #Results' actual columns,
	-- ignore it rather than returning an empty result set.
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
		DECLARE @ColumnsSql NVARCHAR(MAX) = N'';

		SELECT @ColumnsSql = @ColumnsSql
			+ N',' + CHAR(13) + CHAR(10) + CHAR(9)
			+ QUOTENAME(c.name)
			+ CASE WHEN @CompanyCount = 1 THEN ISNULL((
				SELECT TOP 1 N' AS ' + QUOTENAME(c.name + N':' + l.FieldLabel)
				FROM @CustomFieldLabels l
				WHERE l.FieldLabel IS NOT NULL
				  AND c.name = N'Custom' + l.SlotType + N'Value' + CAST(l.SlotNumber AS NVARCHAR(2))
			  ), N'') ELSE N'' END
		FROM tempdb.sys.columns c
		WHERE c.object_id = OBJECT_ID('tempdb..#Results')
		  AND (
				@HasColumnFilter = 0
				OR EXISTS (SELECT 1 FROM @RequestedColumns rc WHERE rc.ColumnName = c.name)
			  )
		ORDER BY c.column_id;

		SET @ColumnsSql = STUFF(@ColumnsSql, 1, 1, N'');  -- strip leading comma

		DECLARE @FinalSql NVARCHAR(MAX) = N'SELECT ' + @ColumnsSql + N' FROM #Results;';

		EXEC sp_executeSQL @FinalSql;
	END
	ELSE
	BEGIN
		SELECT * FROM #Results;
	END

	IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;

	-- =============================================
	-- DEBUG OUTPUT (Optional)
	-- =============================================
	IF @DebugMode = 1
	BEGIN
		DECLARE @DebugOutput NVARCHAR(MAX) =
			'Debug Info - sp_GVOverview_v4' + CHAR(13) + CHAR(10) +
			'UserId: ' + CAST(@UserId AS VARCHAR(20)) + CHAR(13) + CHAR(10) +
			'AllCompanies: ' + CAST(@AllCompanies AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllCountries: ' + CAST(@AllCountries AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllRegions: ' + CAST(@AllRegions AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllCaseTypes: ' + CAST(@AllCaseTypes AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllUsers: ' + CAST(@AllUsers AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'CompanyCount: ' + CAST(@CompanyCount AS VARCHAR(20)) + CHAR(13) + CHAR(10) +
			'CustomFieldsIncluded: ' + CASE WHEN @CompanyCount = 1 THEN 'YES' ELSE 'NO (requires exactly one company)' END + CHAR(13) + CHAR(10) +
			'ColumnFilterApplied: ' + CASE WHEN @HasColumnFilter = 1 THEN 'YES' WHEN @ColumnList IS NOT NULL THEN 'NO (no requested column matched - returned all columns)' ELSE 'NO (no @ColumnList provided)' END + CHAR(13) + CHAR(10) +
			'Limit: ' + CAST(@Limit AS VARCHAR(20)) + CHAR(13) + CHAR(10) +
			'Offset: ' + CAST(@Offset AS VARCHAR(20));

		PRINT @DebugOutput;
	END

END
GO

-- =============================================
-- VERIFICATION SCRIPT - Run this to validate syntax
-- =============================================
-- Uncomment below to verify the procedure was created successfully
-- EXEC sp_helptext '[bdp_rpt].[sp_GVOverview_v4]';
-- GO

-- Recommended follow-up: Create the following indexes for optimal performance
-- (Execute separately in maintenance window)
/*
CREATE INDEX IX_ProjectBeneficiary_CompanySK_Active
  ON rpt.vw_ProjectBeneficiary_BaseTable (company_sk, [Contact Active])
  INCLUDE ([Beneficiary_SK], [CaseId], [case country code], [Case Region])
  WHERE [BeneficiaryIncludedInProject] = 1;

CREATE INDEX IX_StatusDocs_BeneficiarySK_Tracking
  ON rpt.vw_StatusDocs_BaseTable (Beneficiary_SK, [Is Tracking])
  INCLUDE ([Doc Type], [Classification], [Expiration Date])
  WHERE [Is Document] = 1;

CREATE INDEX IX_ProcessDetail_CaseId_Latest
  ON dbo.dim_ProcessDetail (CaseId, DateCreated DESC)
  INCLUDE ([ANZSCOOccupation], [BriefingCallDate], [WeeklyWorkingHours]);

-- Dim_Company is looked up by primary key (Company_SK) only when @CompanyCount = 1,
-- so no additional index should be required beyond the existing PK/clustered index.

-- NEW in v3: see GVOverview_v3_Fact_EBill_Index.sql (in this same folder) for a
-- corrected, narrower covering index on dbo.Fact_EBill supporting the EBillLatest
-- CTE's base table read. That script's header explains what it does and does not
-- fix - it is a smaller, complementary improvement to the EBillCaseFilter change
-- above, not a substitute for it.

-- NEW in v4: @ColumnList reads column names entirely from #Results' own metadata
-- (tempdb.sys.columns), so no new index or table dependency is introduced.

-- Statistics maintenance (run daily during off-peak hours)
UPDATE STATISTICS rpt.vw_ProjectBeneficiary_BaseTable;
UPDATE STATISTICS rpt.vw_StatusDocs_BaseTable;
UPDATE STATISTICS dbo.dim_ProcessDetail;
*/
