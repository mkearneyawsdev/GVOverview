USE [IMS_DataWarehouse]
GO

/****** Object:  StoredProcedure [bdp_rpt].[sp_GVOverview]    Script Date: 9/15/2026 1:32:20 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO




-- =============================================
-- Author:		David Widmark
-- Create date: 12 Dec 2017
-- Description:	GV Overview report - all projects with all linked beneficiaries, joining immigration documents
-- Update: 05/11/2022 - Added Application Location, Application Date and Other Application Location 
-- Update: 1/17/2024 - ddcruz - DL-571 - added column [Location at time of filing application]
-- Update: 9/13/2024 - ddcruz - DL-725 - added columns 
-- 		Briefing Call Date
-- 		Weekly Working Hours
-- 		Exempt from COMPASS assessment?
-- 		Eligible for a 5 year EP for experienced tech professionals with skills in shortage?
-- 		C1 – Salary
-- 		C2 – Qualifications
-- 		C3 – Diversity
-- 		C4 – Support for Local Employment
-- 		C5 – Skills Bonus
-- 		C6 – Strategic Economic Priorities Bonus
-- 		Shortage Occupation List (SOL)?
-- 		Date Education Date Initiated
-- 		Date Education Date Completed
		
-- =============================================
CREATE   PROCEDURE [bdp_rpt].[sp_GVOverview]

	--in this version no parameters are required
	--standard input parameters
	@UserId INT = NULL
	, @ColumnList NVARCHAR(MAX) = NULL --comma-separated list. include all cols when NULL
	-- , @IncludeCustomFields BIT = 0  --only returnworks when one company_sk in @CompanyIds is passed in
	, @Limit INT = 0
	, @Offset INT = 0
	, @CountryCodes NVARCHAR(MAX) = N'ALL'
	, @Region NVARCHAR(MAX) = N'[All]'

	--report-specific input parameters
	, @CompanyIds NVARCHAR(MAX) = N'-1' --comma-separated list.
	, @BALTeamUserIds NVARCHAR(MAX) = N'-1' --comma-separated list.
	, @ClosedProjects BIT = 0 
	, @IncludeDependents BIT = 1 
	, @ExcludeSubProjects BIT = 0
	, @ClosedProfiles BIT = 0
	, @Tracked BIT = 1
	, @CaseType NVARCHAR(MAX) = N'[All]' 

AS
BEGIN

	SET ARITHABORT OFF;
	SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

	/*
	IF THE REPORT HAS ANY REQUIRED PARAMETERS, ESCAPE HERE IF THEY'RE NOT PASSED IN
	--testing omission of this
	IF ISNULL(@UserId,0) = 0 OR ISNULL(@CompanyIds,N'0') = N'0' RETURN;
	*/

	/* 
	ALL REPORT PROCS INCLUDING LISTS MUST USE FACT-JOINED VIEWS AND 
	CALL SP_SET_SESSION_CONTEXT() FOR THE APPLICATION USERID! EXCEPTIONS MUST BE APPROVED!
	*/
	EXEC sp_set_session_context @key=N'UserId', @value=@UserId;


	/* BUILD COMPANY FILTER */
	--Table variables passed into sp_executeSQL must be a user-defined table type rather than a generic table variable
	DECLARE @Company_SKs AS bdp_rpt_sup.IntIdList; --TABLE(Company_SK BIGINT);
	DECLARE @AllCompanies BIT = 0;
	DECLARE @CompanyCount INT = 0;

	IF LEFT(@CompanyIds,2) = N'-1' 
		SELECT @AllCompanies = 1
	ELSE
		BEGIN
			INSERT INTO @Company_SKs 
			SELECT [Value] FROM STRING_SPLIT(@CompanyIds, ',');
			--this really isn't needed, replacing with normal string_split above.
			--SELECT Company_SK FROM rpt.fn_CompanyInputListArray(@CompanyIds);
		
			--count the companies for custom field calc
			SELECT @CompanyCount = @@ROWCOUNT
		END	


		/* BUILD USER FILTER */
	DECLARE @BalTeam AS bdp_rpt_sup.IntIdList; --TABLE(UserId INT);
	DECLARE @AllUsers BIT = 0;
	
	IF LEFT(@BALTeamUserIds,2) = N'-1' 
		SELECT @AllUsers = 1
	ELSE
		INSERT INTO @BalTeam 
		SELECT CAST([Value] AS INT) FROM STRING_SPLIT(@BALTeamUserIds, ',');

			/* BUILD CASE FILTER */

	DECLARE @casetypes AS bdp_rpt_sup.StringIdList; --TABLE(CountryCode VARCHAR(3));
	DECLARE @AllCasetypes BIT = 0;

	
	IF LEFT(@Casetype,5) = N'[All]' 
		SELECT @AllCasetypes = 1
	IF CHARINDEX('ALL', @Casetype) > 0
		SELECT @AllCasetypes = 1
	ELSE
		INSERT INTO @casetypes
		SELECT [Value] FROM STRING_SPLIT(@CaseType, ',');

	
	/* BUILD COUNTRY FILTER */
	DECLARE @Countries AS bdp_rpt_sup.StringIdList; --TABLE(CountryCode VARCHAR(3));
	DECLARE @AllCountries BIT = 0;

	IF CHARINDEX('ALL', @CountryCodes) > 0
		SELECT @AllCountries = 1
	ELSE
		INSERT INTO @Countries 
		SELECT [Value] FROM STRING_SPLIT(@CountryCodes, ',');


	/* BUILD COUNTRY FILTER */
	DECLARE @Regions AS bdp_rpt_sup.StringIdList; --TABLE(CountryCode VARCHAR(3));
	DECLARE @AllRegions BIT = 0;

	
	IF LEFT(@Region,5) = N'[All]' 
		SELECT @AllRegions = 1
	IF CHARINDEX('ALL', @Region) > 0
		SELECT @AllRegions = 1
	ELSE
		INSERT INTO @Regions
		SELECT [Value] FROM STRING_SPLIT(@Region, ',');
	
	

	
DECLARE @SELECT NVARCHAR(MAX) = '

	
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
		p.[Project Job Description],
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
		COALESCE(pb.[Work City] + '', '' + pb.[Work Country], pb.[Work City], pb.[Work Country]) [Profile Work Location],
		COALESCE(pb.[Work 2nd City] + '', '' + pb.[Work 2nd Country], pb.[Work 2nd City], pb.[Work 2nd Country]) [Profile Work Location 2],
		ISNULL(pb.[Residence Address Line 1] ,'''') + ISNULL('' '' + pb.[Residence Address Line 2],'''') + ISNULL('' '' + pb.[Residence Suite], '''') + ISNULL('' '' + pb.[Residence City], '''') + ISNULL('' '' + pb.[Residence State], '''') + ISNULL('' '' + pb.[Residence Postal Code], '''') + ISNULL('' '' + pb.[Residence Country], '''') AS [Current Residence Address],
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
		CASE WHEN pb.[User Login Method]=''Internal'' AND pb.[WebAccess]=1 AND pb.[IsActive]=1 THEN ''Web Access Active''
		WHEN  pb.[User Login Method]=''Internal'' AND pb.[WebAccess]=1 AND pb.[IsActive]=0 THEN ''Web Access Inactive''
		WHEN  pb.[User Login Method]=''Internal'' AND pb.[WebAccess]=0 THEN ''No Web Access''
		WHEN  pb.[User Login Method] in (''SSO'',''GOAUTH'') AND pb.[WebAccess]=1 THEN ''Web Access Active''
		ELSE ''No Web Access'' END as [Web Access],
		CASE WHEN pb.[User Login Method]=''Internal'' THEN ''Username/Password'' Else pb.[User Login Method] END as [Access Type],
		pb.[All Info Recd] [All Info Received],
		pb.[Is Principal],
		pb.[Residence Appointment Date],
		pb.[IRP Card Received by Service Provider?],
		p.[LMT Advertising Expiry],
		p.[IPA Expiry],
		p.[PEA Expiry Pre-Entry Approval],
		p.[COE Expiry],
        p.[DGIM Approval Expiry],
        p.[EP/DP/PVP Approval Letter Expiry],
		pb.[company_sk],
		pb.[project_SK],
		pb.[case country code], 
		pb.[Contact Active],
		CASE When pb.[Contact Active] = 1 Then ''Yes'' Else ''No'' End as [Open Profile (Yes/No)],
		--pb.[Profile Closed Date],
        pb.[BALManagerUserId]  
       ,pb.[BALAssistantUserId]
       ,pb.[BALManager2UserId]
       ,pb.[BALAssistant2UserId]
       ,pb.[BALManager3UserId]
       ,pb.[BALAssistant3UserId]
	   ,p.[Application Location]
	   ,p.[Application Date]
	   ,p.[Other Application Location]
	   ,pd.[ANZSCOOccupation] as [ANZSCO Occupation]
	   ,pd.Locationattimeoffilingapplication as [Location at time of filing application]

	   -- DL-725
	   ,pd.BriefingCallDate AS [Briefing Call Date]
	   ,pd.WeeklyWorkingHours AS [Weekly Working Hours]

       ,pd.ExemptfromCOMPASSassessment AS [Exempt from COMPASS assessment?]
       ,pd.Eligiblefora5yearEPforexperiencedtechprofessionalswithskillsinshortage AS [Eligible for a 5 year EP for experienced tech professionals with skills in shortage?]
       ,pd.C1Salary AS [C1 – Salary]
       ,pd.C2Qualifications AS [C2 – Qualifications]
       ,pd.C3Diversity AS [C3 – Diversity]
       ,pd.C4SupportforLocalEmployment AS [C4 – Support for Local Employment]
       ,pd.C5SkillsBonus AS [C5 – Skills Bonus]
       ,pd.C6StrategicEconomicPrioritiesBonus AS [C6 – Strategic Economic Priorities Bonus]
       ,pd.ShortageOccupationList AS [Shortage Occupation List (SOL)?]
       ,pd.DateEducationCheckInitiated AS [Date Education Check Initiated]
       ,pd.DateEducationCheckCompleted AS [Date Education Check Completed]
	   ,pd.[DocumentDraftCompleted] AS [Document Draft Completed]
	   ,pd.DecisionDueEmployee AS [Decision Due - Employee]
       ,pd.DecisionDueDependents AS [Decision Due - Dependent(s)]

		--CUSTOM
	FROM rpt.vw_ProjectBeneficiary AS pb WITH (NOLOCK)
	LEFT JOIN rpt.vw_StatusDocs sd WITH (NOLOCK) ON pb.Beneficiary_SK = sd.Beneficiary_SK
		AND pb.[Country Code] = sd.[Country Code]
		AND sd.[Is Document] = 1
		--ONLYTRACKING
		
    LEFT JOIN 
	(
		
	
 SELECT CaseId, CASE WHEN [Fee Status] = ''PENDING_APPROVAL'' THEN ''YES'' ELSE ''NO'' END [Bills Pending Approval],
                                           ROW_NUMBER() OVER(PARTITION BY CaseId ORDER BY [Approved Date] DESC ) RN
                                           FROM rpt.vw_EBill 

	) as 
	 ebill ON pb.CaseId = ebill.CaseId AND ebill.RN = 1
	LEFT JOIN rpt.vw_Project p ON pb.CaseId = p.CaseId
	--LEFT JOIN rpt.vw_user u on pb.[Userid] = u.[Userid]
	LEFT JOIN dbo.dim_ProcessDetail pd ON pd.CaseId = pb.CaseId

	WHERE
		
		pb.[BeneficiaryIncludedInProject] = 1 
		 

		
		

'


	DECLARE @CustomFieldSelect VARCHAR(MAX);

	IF @CompanyCount = 1 --AND @IncludeCustomFields = 1
	BEGIN
		DECLARE @Company_SK INT;
		SELECT TOP 1 @Company_SK = Id FROM @Company_SKs;
		SELECT @CustomFieldSelect = 
		ISNULL('pb.[CustomProfileValue1] AS [CustomProfileValue1:' + CustomProfileField1 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue1],') +
		ISNULL('pb.[CustomProfileValue2] AS [CustomProfileValue2:' + CustomProfileField2 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue2],') +
		ISNULL('pb.[CustomProfileValue3] AS [CustomProfileValue3:' + CustomProfileField3 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue3],') +
		ISNULL('pb.[CustomProfileValue4] AS [CustomProfileValue4:' + CustomProfileField4 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue4],') +
		ISNULL('pb.[CustomProfileValue5] AS [CustomProfileValue5:' + CustomProfileField5 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue5],') +
		ISNULL('pb.[CustomProfileValue6] AS [CustomProfileValue6:' + CustomProfileField6 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue6],') +
		ISNULL('pb.[CustomProfileValue7] AS [CustomProfileValue7:' + CustomProfileField7 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue7],') +
		ISNULL('pb.[CustomProfileValue8] AS [CustomProfileValue8:' + CustomProfileField8 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue8],') +
		ISNULL('pb.[CustomProfileValue9] AS [CustomProfileValue9:' + CustomProfileField9 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue9],') +
		ISNULL('pb.[CustomProfileValue10] AS [CustomProfileValue10:' + CustomProfileField10 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue10],') +
		ISNULL('pb.[CustomProfileValue11] AS [CustomProfileValue11:' + CustomProfileField11 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue11],') +
		ISNULL('pb.[CustomProfileValue12] AS [CustomProfileValue12:' + CustomProfileField12 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue12],') +
		ISNULL('pb.[CustomProfileValue13] AS [CustomProfileValue13:' + CustomProfileField13 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue13],') +
		ISNULL('pb.[CustomProfileValue14] AS [CustomProfileValue14:' + CustomProfileField14 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue14],') +
		ISNULL('pb.[CustomProfileValue15] AS [CustomProfileValue15:' + CustomProfileField15 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue15],') +
		ISNULL('pb.[CustomProfileValue16] AS [CustomProfileValue16:' + CustomProfileField16 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue16],') +
		ISNULL('pb.[CustomProfileValue17] AS [CustomProfileValue17:' + CustomProfileField17 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue17],') +
		ISNULL('pb.[CustomProfileValue18] AS [CustomProfileValue18:' + CustomProfileField18 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue18],') +
		ISNULL('pb.[CustomProfileValue19] AS [CustomProfileValue19:' + CustomProfileField19 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue19],') +
		ISNULL('pb.[CustomProfileValue20] AS [CustomProfileValue20:' + CustomProfileField20 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue20],') +
		ISNULL('pb.[CustomProfileValue21] AS [CustomProfileValue21:' + CustomProfileField21 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue21],') +
		ISNULL('pb.[CustomProfileValue22] AS [CustomProfileValue22:' + CustomProfileField22 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue22],') +
		ISNULL('pb.[CustomProfileValue23] AS [CustomProfileValue23:' + CustomProfileField23 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue23],') +
		ISNULL('pb.[CustomProfileValue24] AS [CustomProfileValue24:' + CustomProfileField24 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue24],') +
		ISNULL('pb.[CustomProfileValue25] AS [CustomProfileValue25:' + CustomProfileField25 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue25],') +
		ISNULL('pb.[CustomProfileValue26] AS [CustomProfileValue26:' + CustomProfileField26 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue26],') +
		ISNULL('pb.[CustomProfileValue27] AS [CustomProfileValue27:' + CustomProfileField27 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue27],') +
		ISNULL('pb.[CustomProfileValue28] AS [CustomProfileValue28:' + CustomProfileField28 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue28],') +
		ISNULL('pb.[CustomProfileValue29] AS [CustomProfileValue29:' + CustomProfileField29 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue29],') +
		ISNULL('pb.[CustomProfileValue30] AS [CustomProfileValue30:' + CustomProfileField30 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue30],') +
		ISNULL('pb.[CustomProfileValue31] AS [CustomProfileValue31:' + CustomProfileField31 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue31],') +
		ISNULL('pb.[CustomProfileValue32] AS [CustomProfileValue32:' + CustomProfileField32 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue32],') +
		ISNULL('pb.[CustomProfileValue33] AS [CustomProfileValue33:' + CustomProfileField33 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue33],') +
		ISNULL('pb.[CustomProfileValue34] AS [CustomProfileValue34:' + CustomProfileField34 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue34],') +
		ISNULL('pb.[CustomProfileValue35] AS [CustomProfileValue35:' + CustomProfileField35 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue35],') +
		ISNULL('pb.[CustomProfileValue36] AS [CustomProfileValue36:' + CustomProfileField36 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue36],') +
		ISNULL('pb.[CustomProfileValue37] AS [CustomProfileValue37:' + CustomProfileField37 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue37],') +
		ISNULL('pb.[CustomProfileValue38] AS [CustomProfileValue38:' + CustomProfileField38 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue38],') +
		ISNULL('pb.[CustomProfileValue39] AS [CustomProfileValue39:' + CustomProfileField39 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue39],') +
		ISNULL('pb.[CustomProfileValue40] AS [CustomProfileValue40:' + CustomProfileField40 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue40],') +
		ISNULL('pb.[CustomProfileValue41] AS [CustomProfileValue41:' + CustomProfileField41 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue41],') +
		ISNULL('pb.[CustomProfileValue42] AS [CustomProfileValue42:' + CustomProfileField42 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue42],') +
		ISNULL('pb.[CustomProfileValue43] AS [CustomProfileValue43:' + CustomProfileField43 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue43],') +
		ISNULL('pb.[CustomProfileValue44] AS [CustomProfileValue44:' + CustomProfileField44 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue44],') +
		ISNULL('pb.[CustomProfileValue45] AS [CustomProfileValue45:' + CustomProfileField45 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue45],') +
		ISNULL('pb.[CustomProfileValue46] AS [CustomProfileValue46:' + CustomProfileField46 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue46],') +
		ISNULL('pb.[CustomProfileValue47] AS [CustomProfileValue47:' + CustomProfileField47 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue47],') +
		ISNULL('pb.[CustomProfileValue48] AS [CustomProfileValue48:' + CustomProfileField48 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue48],') +
		ISNULL('pb.[CustomProfileValue49] AS [CustomProfileValue49:' + CustomProfileField49 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue49],') +
		ISNULL('pb.[CustomProfileValue50] AS [CustomProfileValue50:' + CustomProfileField50 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue50],') +


		ISNULL('pb.[CustomProjectValue1] AS [CustomProjectValue1:' + CustomProjectField1 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue1],') +
		ISNULL('pb.[CustomProjectValue2] AS [CustomProjectValue2:' + CustomProjectField2 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue2],') +
		ISNULL('pb.[CustomProjectValue3] AS [CustomProjectValue3:' + CustomProjectField3 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue3],') +
		ISNULL('pb.[CustomProjectValue4] AS [CustomProjectValue4:' + CustomProjectField4 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue4],') +
		ISNULL('pb.[CustomProjectValue5] AS [CustomProjectValue5:' + CustomProjectField5 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue5],') +
		ISNULL('pb.[CustomProjectValue6] AS [CustomProjectValue6:' + CustomProjectField6 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue6],') +
		ISNULL('pb.[CustomProjectValue7] AS [CustomProjectValue7:' + CustomProjectField7 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue7],') +
		ISNULL('pb.[CustomProjectValue8] AS [CustomProjectValue8:' + CustomProjectField8 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue8],') +
		ISNULL('pb.[CustomProjectValue9] AS [CustomProjectValue9:' + CustomProjectField9 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue9],') +
		ISNULL('pb.[CustomProjectValue10] AS [CustomProjectValue10:' + CustomProjectField10 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue10],') +
		ISNULL('pb.[CustomProjectValue11] AS [CustomProjectValue11:' + CustomProjectField11 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue11],') +
		ISNULL('pb.[CustomProjectValue12] AS [CustomProjectValue12:' + CustomProjectField12 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue12],') +
		ISNULL('pb.[CustomProjectValue13] AS [CustomProjectValue13:' + CustomProjectField13 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue13],') +
		ISNULL('pb.[CustomProjectValue14] AS [CustomProjectValue14:' + CustomProjectField14 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue14],') +
		ISNULL('pb.[CustomProjectValue15] AS [CustomProjectValue15:' + CustomProjectField15 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue15],') +
		ISNULL('pb.[CustomProjectValue16] AS [CustomProjectValue16:' + CustomProjectField16 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue16],') +
		ISNULL('pb.[CustomProjectValue17] AS [CustomProjectValue17:' + CustomProjectField17 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue17],') +
		ISNULL('pb.[CustomProjectValue18] AS [CustomProjectValue18:' + CustomProjectField18 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue18],') +
		ISNULL('pb.[CustomProjectValue19] AS [CustomProjectValue19:' + CustomProjectField19 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue19],') +
		ISNULL('pb.[CustomProjectValue20] AS [CustomProjectValue20:' + CustomProjectField20 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue20],') +
		ISNULL('pb.[CustomProjectValue21] AS [CustomProjectValue21:' + CustomProjectField21 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue21],') +
		ISNULL('pb.[CustomProjectValue22] AS [CustomProjectValue22:' + CustomProjectField22 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue22],') +
		ISNULL('pb.[CustomProjectValue23] AS [CustomProjectValue23:' + CustomProjectField23 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue23],') +
		ISNULL('pb.[CustomProjectValue24] AS [CustomProjectValue24:' + CustomProjectField24 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue24],') +
		ISNULL('pb.[CustomProjectValue25] AS [CustomProjectValue25:' + CustomProjectField25 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue25],') +
		ISNULL('pb.[CustomProjectValue26] AS [CustomProjectValue26:' + CustomProjectField26 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue26],') +
		ISNULL('pb.[CustomProjectValue27] AS [CustomProjectValue27:' + CustomProjectField27 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue27],') +
		ISNULL('pb.[CustomProjectValue28] AS [CustomProjectValue28:' + CustomProjectField28 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue28],') +
		ISNULL('pb.[CustomProjectValue29] AS [CustomProjectValue29:' + CustomProjectField29 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue29],') +
		ISNULL('pb.[CustomProjectValue30] AS [CustomProjectValue30:' + CustomProjectField30 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue30],') +
		ISNULL('pb.[CustomProjectValue31] AS [CustomProjectValue31:' + CustomProjectField31 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue31],') +
		ISNULL('pb.[CustomProjectValue32] AS [CustomProjectValue32:' + CustomProjectField32 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue32],') +
		ISNULL('pb.[CustomProjectValue33] AS [CustomProjectValue33:' + CustomProjectField33 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue33],') +
		ISNULL('pb.[CustomProjectValue34] AS [CustomProjectValue34:' + CustomProjectField34 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue34],') +
		ISNULL('pb.[CustomProjectValue35] AS [CustomProjectValue35:' + CustomProjectField35 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue35],') +
		ISNULL('pb.[CustomProjectValue36] AS [CustomProjectValue36:' + CustomProjectField36 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue36],') +
		ISNULL('pb.[CustomProjectValue37] AS [CustomProjectValue37:' + CustomProjectField37 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue37],') +
		ISNULL('pb.[CustomProjectValue38] AS [CustomProjectValue38:' + CustomProjectField38 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue38],') +
		ISNULL('pb.[CustomProjectValue39] AS [CustomProjectValue39:' + CustomProjectField39 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue39],') +
		ISNULL('pb.[CustomProjectValue40] AS [CustomProjectValue40:' + CustomProjectField40 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue40],') +
		ISNULL('pb.[CustomProjectValue41] AS [CustomProjectValue41:' + CustomProjectField41 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue41],') +
		ISNULL('pb.[CustomProjectValue42] AS [CustomProjectValue42:' + CustomProjectField42 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue42],') +
		ISNULL('pb.[CustomProjectValue43] AS [CustomProjectValue43:' + CustomProjectField43 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue43],') +
		ISNULL('pb.[CustomProjectValue44] AS [CustomProjectValue44:' + CustomProjectField44 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue44],') +
		ISNULL('pb.[CustomProjectValue45] AS [CustomProjectValue45:' + CustomProjectField45 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue45],') +
		ISNULL('pb.[CustomProjectValue46] AS [CustomProjectValue46:' + CustomProjectField46 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue46],') +
		ISNULL('pb.[CustomProjectValue47] AS [CustomProjectValue47:' + CustomProjectField47 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue47],') +
		ISNULL('pb.[CustomProjectValue48] AS [CustomProjectValue48:' + CustomProjectField48 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue48],') +
		ISNULL('pb.[CustomProjectValue49] AS [CustomProjectValue49:' + CustomProjectField49 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue49],') +
		ISNULL('pb.[CustomProjectValue50] AS [CustomProjectValue50:' + CustomProjectField50 + '],', 'CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue50],')  

		FROM Dim_Company 
		WHERE Company_SK = @Company_SK;

		IF RIGHT(@CustomFieldSelect,1) = ','
			SET @CustomFieldSelect = LEFT(@CustomFieldSelect, LEN(@CustomFieldSelect)-1);
		
	END

	ELSE

	BEGIN

		SELECT @CustomFieldSelect = '
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue1],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue2],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue3],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue4],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue5],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue6],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue7],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue8],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue9],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue10],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue11],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue12],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue13],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue14],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue15],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue16],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue17],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue18],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue19],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue20],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue21],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue22],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue23],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue24],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue25],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue26],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue27],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue28],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue29],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue30],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue31],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue32],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue33],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue34],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue35],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue36],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue37],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue38],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue39],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue40],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue41],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue42],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue43],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue44],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue45],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue46],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue47],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue48],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue49],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProfileValue50],

		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue1],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue2],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue3],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue4],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue5],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue6],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue7],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue8],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue9],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue10],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue11],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue12],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue13],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue14],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue15],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue16],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue17],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue18],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue19],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue20],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue21],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue22],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue23],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue24],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue25],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue26],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue27],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue28],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue29],
        CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue30],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue31],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue32],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue33],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue34],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue35],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue36],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue37],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue38],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue39],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue40],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue41],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue42],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue43],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue44],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue45],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue46],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue47],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue48],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue49],
		CAST(NULL AS VARCHAR(4000)) AS [CustomProjectValue50]
		'
	END

	--IF @CustomFieldSelect IS NOT NULL
	SET @SELECT = REPLACE(@SELECT, '--CUSTOM', ', ' + @CustomFieldSelect);

	

	DECLARE @QUERY NVARCHAR(MAX) = '
	SELECT
	**COLUMNS**
	FROM (
	**SELECT**
	) AS base
	WHERE 0=0
'
	SET @QUERY = REPLACE(@QUERY,'**SELECT**',@SELECT)


/* COLUMNS */
	IF @ColumnList IS NOT NULL
		BEGIN
			--bracket-wrapping column names if not already done.  this could be done better
			IF CHARINDEX('[',@ColumnList) = 0
				SET @ColumnList = '[' + REPLACE(@ColumnList ,',','],[') + ']'

			SET @QUERY = REPLACE(@QUERY,'**COLUMNS**',@ColumnList)
		END

	ELSE
		BEGIN
			SET @QUERY = REPLACE(@QUERY,'**COLUMNS**','*')
		END


	--replacing (p.[Close] IS NULL OR @ClosedProjects=1) AND
	IF NOT @ClosedProjects = 1 
		SET @QUERY = @QUERY + '
	AND [Close] IS NULL
'


	
	--replacing @AllCompanies = 1 OR p.Company_SK IN (SELECT Company_SK FROM @Company_SKs)
	IF NOT @AllCompanies = 1
		SET @QUERY = @QUERY + '
		AND Company_SK IN (SELECT Id FROM @Company_SKs)
'

	IF NOT @AllCountries = 1
		SET @QUERY = @QUERY + '
	AND [Case Country Code] IN (SELECT Id FROM @Countries)
	'

	IF NOT @AllRegions = 1
		SET @QUERY = @QUERY + '
	AND [Case Region]  IN (SELECT Id FROM @Regions)
	'

    --replacing (p.[Contact Active] = 1 OR @ClosedProfiles=1) AND
	IF NOT @ClosedProfiles = 1 
		SET @QUERY = @QUERY + '
	AND [Contact Active] = 1
'


	IF NOT @AllCaseTypes = 1
		SET @QUERY = @QUERY + '
		AND [Case Type] IN (SELECT Id FROM @casetypes)
'	

	--replacing (p.[Contact Active] = 1 OR @ClosedProfiles=1) AND
	IF NOT @Tracked = 1
		SET @QUERY = REPLACE(@QUERY, '--ONLYTRACKING',
	'AND sd.[Is Tracking] = 1')
		
	--replacing @AllUsers OR (p.[BALManagerUserId] IN (SELECT UserId FROM @BALTeam) OR --etc...
	IF NOT @AllUsers = 1
		SET @QUERY = @QUERY + '
	AND (
		[BALManagerUserId]  IN (SELECT Id FROM @BALTeam) OR
		[BALAssistantUserId] IN (SELECT Id FROM @BALTeam) OR
		[BALManager2UserId] IN (SELECT Id FROM @BALTeam) OR
		[BALAssistant2UserId] IN (SELECT Id FROM @BALTeam) OR
		[BALManager3UserId] IN (SELECT Id FROM @BALTeam) OR
		[BALAssistant3UserId] IN (SELECT Id FROM @BALTeam) 
	)
'
IF NOT @IncludeDependents = 1 
		SET @QUERY = @QUERY + '
	AND [Is Principal]=1
'




		
	--replacing p.[Parent CaseId] IS NULL or ISNULL(@ExcludeSubProjects,0)=0

	IF NOT @ExcludeSubProjects = 0
	SET @QUERY = @QUERY + '
	AND [Parent CaseId] IS NULL
'
	
IF @UserId IS NULL
		SET @QUERY = @QUERY + '
	AND 0 = 1
'


	/* 
	OFFSET AND LIMIT 
	*/

	IF @Offset > 0 OR @Limit > 0
	SET @QUERY = @QUERY + '
	ORDER BY Project_SK
	OFFSET ' + CAST(@Offset AS VARCHAR(20)) + ' ROWS
'
	IF @Limit > 0
	SET @QUERY = @QUERY + '
	FETCH NEXT ' + CAST(@Limit AS VARCHAR(20)) + ' ROWS ONLY
'
	

	-- UNCOMMENT TO VIEW GENERATED SQL
	
	-- PRINT LEFT(@QUERY,4000)
	-- PRINT SUBSTRING(@QUERY,4001,4000)
	-- PRINT SUBSTRING(@QUERY,8001,4000)
	-- PRINT SUBSTRING(@QUERY,12001,4000)
	

	/* 
	EXECUTE QUERY 
	*/
	EXEC sp_executeSQL @QUERY, 
		N'@Company_SKs bdp_rpt_sup.IntIdList readonly,  @BALTeam bdp_rpt_sup.IntIdList readonly, @Countries bdp_rpt_sup.StringIdList readonly,@Regions bdp_rpt_sup.StringIdList readonly, @CaseTypes bdp_rpt_sup.StringIdList readonly',
		@Company_SKs, @BALTeam,@Countries,@Regions,@CaseTypes
	

END
GO



