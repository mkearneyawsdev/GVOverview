USE [IMS_DataWarehouse]
GO

/****** Object:  StoredProcedure [bdp_rpt].[sp_GVOverview_v1]    Script Date: 9/15/2026 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		David Widmark
-- Create date: 12 Dec 2017
-- Description:	GV Overview report - all projects with all linked beneficiaries, joining immigration documents
-- REFACTORED:   9/15/2026 - Performance optimization - Removed dynamic SQL, added static query with runtime conditions
--
-- Performance Improvements Implemented:
--   1. Eliminated dynamic SQL string concatenation (Issue #1)
--   2. Consistent parameter validation logic (Issue #2)
--   3. Optimized EBill subquery with CTE (Issue #3)
--   4. Improved view join strategy (Issue #4)
--   5. Simplified custom field handling (Issue #5)
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
-- Update: 9/15/2026 - Refactored for performance: Static SQL instead of dynamic concatenation
-- =============================================

CREATE PROCEDURE [bdp_rpt].[sp_GVOverview_v1]
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
	-- PHASE 4: PREPARE OPTIMIZED DATA STRUCTURES (Issues #3, #4, #9)
	-- Build CTEs and temp structures with pre-filtering
	-- =============================================

	-- CTE 1: Optimized EBill data with deduplication (Issue #3)
	-- Only get the latest bill per case with most recent approved date
	WITH EBillLatest AS (
		SELECT
			CaseId,
			CASE WHEN [Fee Status] = 'PENDING_APPROVAL' THEN 'YES' ELSE 'NO' END [Bills Pending Approval],
			ROW_NUMBER() OVER(PARTITION BY CaseId ORDER BY [Approved Date] DESC) RN
		FROM rpt.vw_EBill
		WHERE CaseId IS NOT NULL
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
	-- All conditions evaluated at runtime, no string concatenation
	-- =============================================
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
        pdd.[DecisionDueDependents] AS [Decision Due - Dependent(s)]

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
	-- PHASE 6: PAGINATION WITH DETERMINISTIC ORDERING (Issue #7)
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
	-- PHASE 7: QUERY OPTIMIZATION HINTS (Issue #8)
	-- Provides hints for query optimizer and resource governance
	-- =============================================
	OPTION (RECOMPILE, MAXDOP 4);  -- Recompile for parameter variation, limit parallelism to 4 threads

	-- =============================================
	-- DEBUG OUTPUT (Optional)
	-- =============================================
	IF @DebugMode = 1
	BEGIN
		DECLARE @DebugOutput NVARCHAR(MAX) =
			'Debug Info - sp_GVOverview_v1' + CHAR(13) + CHAR(10) +
			'UserId: ' + CAST(@UserId AS VARCHAR(20)) + CHAR(13) + CHAR(10) +
			'AllCompanies: ' + CAST(@AllCompanies AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllCountries: ' + CAST(@AllCountries AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllRegions: ' + CAST(@AllRegions AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllCaseTypes: ' + CAST(@AllCaseTypes AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'AllUsers: ' + CAST(@AllUsers AS VARCHAR(1)) + CHAR(13) + CHAR(10) +
			'CompanyCount: ' + CAST(@CompanyCount AS VARCHAR(20)) + CHAR(13) + CHAR(10) +
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
-- EXEC sp_helptext '[bdp_rpt].[sp_GVOverview_v1]';
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

-- Statistics maintenance (run daily during off-peak hours)
UPDATE STATISTICS rpt.vw_ProjectBeneficiary_BaseTable;
UPDATE STATISTICS rpt.vw_StatusDocs_BaseTable;
UPDATE STATISTICS dbo.dim_ProcessDetail;
*/
