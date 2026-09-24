/* 834 outbound -- load slice 1 as a procedure, with per entity timing in ctl.load_run.  A Sharma, 17 Sep 2026. */

USE [ODM];
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* decimal(9,4) tops out at 99999.9999. A 1,000 row test followed by a 1.49M row load is 148,589%. */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('ctl.load_run') AND name = 'pct_change' AND scale = 4 AND precision < 18)
    ALTER TABLE ctl.load_run ALTER COLUMN pct_change decimal(18,4) NULL;
GO

/* opens a ctl.load_run row and returns its identifier */
CREATE OR ALTER PROCEDURE ctl.usp_run_start
    @entity_name    varchar(64),
    @reference_date date         = NULL,
    @feed_code      varchar(30)  = NULL,
    @run_identifier int          OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT ctl.load_run (entity_name, reference_date, started_at, status_code, feed_code)
    VALUES (@entity_name, @reference_date, SYSDATETIME(), 'RUNNING', @feed_code);
    SET @run_identifier = CAST(SCOPE_IDENTITY() AS int);
END
GO

/* closes a ctl.load_run row: finish time, row count, change against the previous run */
CREATE OR ALTER PROCEDURE ctl.usp_run_finish
    @run_identifier int,
    @rows_loaded    bigint
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entity varchar(64), @prev bigint;

    SELECT @entity = entity_name FROM ctl.load_run WHERE run_identifier = @run_identifier;

    SELECT TOP 1 @prev = rows_loaded_count
    FROM   ctl.load_run
    WHERE  entity_name = @entity AND status_code = 'SUCCEEDED' AND run_identifier < @run_identifier
    ORDER BY run_identifier DESC;

    UPDATE ctl.load_run
    SET    finished_at             = SYSDATETIME(),
           rows_loaded_count       = @rows_loaded,
           rows_previous_run_count = @prev,
           pct_change              = CASE WHEN ISNULL(@prev,0) = 0 THEN NULL
                                          ELSE CAST((@rows_loaded - @prev) * 100.0 / @prev AS decimal(18,4)) END,
           status_code             = 'SUCCEEDED'
    WHERE  run_identifier = @run_identifier;
END
GO

/* marks every open run in this batch as failed, with the reason */
CREATE OR ALTER PROCEDURE ctl.usp_run_fail
    @from_run_identifier int,
    @halt_reason         varchar(400)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE ctl.load_run
    SET    finished_at = SYSDATETIME(), status_code = 'FAILED', halt_reason = @halt_reason
    WHERE  run_identifier >= @from_run_identifier AND status_code = 'RUNNING';
END
GO


CREATE OR ALTER PROCEDURE odm.usp_load_slice_1
    @reference_date date        = NULL,   -- defaults to the first of the current month
    @feed_code      varchar(30) = 'NORTHBAY_M',
    @as_of          date        = NULL,   -- defaults to today
    @stale_hours    int         = 4,      -- a RUNNING row older than this was killed, not failed
    @row_limit      int         = 0       -- 0 = all members; set small for a first run
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run int, @first_run int, @rows bigint, @dups int, @msg nvarchar(2048);
    DECLARE @top int = CASE WHEN @row_limit > 0 THEN @row_limit ELSE 2147483647 END;

    SET @reference_date = ISNULL(@reference_date, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));
    SET @as_of          = ISNULL(@as_of, CAST(GETDATE() AS date));

    BEGIN TRY

        /* pre-flight */
        IF NOT EXISTS (SELECT 1 FROM cfg.publication_feed WHERE feed_code = @feed_code)
            THROW 50001, 'No cfg.publication_feed row for that feed_code.', 1;

        IF @reference_date < '2026-08-01' OR @reference_date >= '2028-01-01'
            THROW 50002, 'reference_date is outside pf_publication_run_date.', 1;

        /* a killed session leaves RUNNING forever - close anything older than the window */
        UPDATE ctl.load_run
        SET    status_code = 'ABANDONED', finished_at = SYSDATETIME(),
               halt_reason = 'No completion recorded. Session terminated.'
        WHERE  status_code = 'RUNNING' AND started_at <= DATEADD(hour, -@stale_hours, SYSDATETIME());

        IF EXISTS (SELECT 1 FROM ctl.load_run WHERE status_code = 'RUNNING')
            THROW 50005, 'Another load is already running.', 1;

        SET @first_run = ISNULL((SELECT MAX(run_identifier) FROM ctl.load_run), 0) + 1;

        /* Empty the targets, children before parents. Slice 1 rebuilds enrollment_member and everything in slice 2 has a foreign key to it, so running slice 1 empties slice 2. They are one refresh. */

        DELETE pub.member_language
        WHERE  reference_date = @reference_date AND feed_code = @feed_code;
        DELETE pub.member_other_insurance
        WHERE  reference_date = @reference_date AND feed_code = @feed_code;
        DELETE pub.member_benefit_plan_span
        WHERE  reference_date = @reference_date AND feed_code = @feed_code;

        DELETE odm.enrollment_other_insurance;
        DELETE odm.enrollment_compliance_program;
        DELETE odm.enrollment_member_attribute;
        DELETE odm.enrollment_provider;
        DELETE odm.enrollment_contact;
        DELETE odm.enrollment_identifier;
        DELETE odm.enrollment_ethnicity;
        DELETE odm.enrollment_language;
        DELETE odm.enrollment_address;

        DELETE odm.enrollment_benefit_plan_span;
        DELETE odm.enrollment_member;
        DELETE odm.enrollment_hcp;

        /* odm.enrollment_hcp -- loads first, enrollment_member has an FK to it */
        EXEC ctl.usp_run_start 'odm.enrollment_hcp', @reference_date, NULL, @run OUTPUT;

        DROP TABLE IF EXISTS #hcp;
        SELECT   hcp_number    = LTRIM(RTRIM(x.STATE_HCP_NUM))
                ,hcp_name      = MAX(x.COUNTY_NAME)
                ,county_code   = MAX(LEFT(x.COUNTY_CODE,2))
                ,county_number = MAX(TRY_CAST(x.COUNTY_NO AS smallint))
                ,county_program_name = MAX(LEFT(x.PROGRAM,30))
        INTO     #hcp
        FROM     ODS_FINAL.XWALK.INT_COUNTY_XWALK x WITH (NOLOCK)
        WHERE    x.STATE_HCP_NUM IS NOT NULL AND LTRIM(RTRIM(x.STATE_HCP_NUM)) <> ''
        GROUP BY LTRIM(RTRIM(x.STATE_HCP_NUM));

        INSERT odm.enrollment_hcp WITH (TABLOCK)
            (hcp_number, hcp_name, county_code, county_number, county_program_name,
             source_member_version_key, insert_batch_id)
        SELECT hcp_number, hcp_name, county_code, county_number, county_program_name, NULL, @run
        FROM   #hcp;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;

        /* odm.enrollment_member */
        EXEC ctl.usp_run_start 'odm.enrollment_member', @reference_date, NULL, @run OUTPUT;

        DROP TABLE IF EXISTS #member;
        SELECT  TOP (@top)
                member_identifier            = LTRIM(RTRIM(m.MEMBER_HCC_ID))
               ,last_name                    = NULLIF(LTRIM(RTRIM(m.MEMBER_LAST_NAME)),'')
               ,first_name                   = NULLIF(LTRIM(RTRIM(m.MEMBER_FIRST_NAME)),'')
               ,middle_name                  = NULLIF(LTRIM(RTRIM(m.MEMBER_MIDDLE_NAME)),'')
               ,name_prefix                  = NULLIF(LTRIM(RTRIM(m.MEMBER_NAME_PREFIX)),'')
               ,name_suffix                  = NULLIF(LTRIM(RTRIM(m.MEMBER_NAME_SUFFIX)),'')
               ,birth_date                   = CAST(m.MEMBER_BIRTH_DATE AS date)
               ,death_date                   = CAST(m.MEMBER_DEATH_DATE AS date)
               ,gender_code                  = LEFT(m.MEMBER_GENDER_CODE,1)
               ,marital_status_code          = LEFT(m.MARITAL_STATUS_CODE,1)
               ,medicare_status_code         = CAST(NULL AS char(1))   -- source not agreed
               ,native_american_alaskan_flag = LEFT(m.IS_NATIVE_AMERICAN_ALASKAN,1)
               ,member_status_code           = LEFT(m.MEMBER_STATUS,1)
               ,hcp_number                   = NULLIF(LTRIM(RTRIM(m.HCP_NUMBER)),'')
               ,enrollment_start_date        = CAST(m.MEMBER_EFFECTIVE_DATE AS date)
               ,enrollment_end_date          = NULLIF(NULLIF(CAST(m.MEMBER_TERMINATION_DATE AS date),'3000-01-01'),'1800-01-01')
               ,employment_status_code       = NULLIF(LTRIM(RTRIM(m.EMPLOYMENT_STATUS_CODE)),'')
               ,source_member_version_key    = m.MEMBER_HISTORY_FACT_KEY
        INTO    #member
        FROM    ODS_FINAL.dbo.MEMBER m WITH (NOLOCK)
        WHERE   (m.VERSION_EFF_DATE <= @as_of OR m.VERSION_EFF_DATE IS NULL)
          AND   (m.VERSION_EXP_DATE  > @as_of OR m.VERSION_EXP_DATE IS NULL)
          AND   ISNULL(m.DELETED_FLAG,'') <> 'Y'
          AND   m.MEMBER_HCC_ID IS NOT NULL
          AND   m.MEMBER_STATUS IS NOT NULL;

        IF @@ROWCOUNT = 0
            THROW 50003, 'Zero members staged. Name resolution or permissions, not a filter.', 1;

        CREATE CLUSTERED INDEX ix_stage_member ON #member (member_identifier);

        SET @dups = (SELECT COUNT(*) FROM (SELECT member_identifier FROM #member
                     GROUP BY member_identifier HAVING COUNT(*) > 1) d);

        /* one current version per member - keep the latest enrollment, tie broken by source key */
        IF @dups > 0
            DELETE x
            FROM  (SELECT rn = ROW_NUMBER() OVER (PARTITION BY member_identifier
                                                  ORDER BY enrollment_start_date DESC,
                                                           source_member_version_key DESC)
                   FROM   #member) x
            WHERE x.rn > 1;

        /* staged only - the write happens in one transaction with the span, below */
        DECLARE @run_member int = @run;

        /* odm.enrollment_benefit_plan_span -- end dates stay exclusive here */
        EXEC ctl.usp_run_start 'odm.enrollment_benefit_plan_span', @reference_date, NULL, @run OUTPUT;
        DECLARE @run_span int = @run;

        DROP TABLE IF EXISTS #span;
        SELECT  member_identifier              = LTRIM(RTRIM(p.MEMBER_HCC_ID))
               ,benefit_plan_identifier        = LEFT(LTRIM(RTRIM(p.BENEFIT_PLAN_HCC_ID)),50)
               ,member_benefit_plan_start_date = CAST(p.MEMBER_PLAN_START_DATE AS date)
               ,member_benefit_plan_end_date   = NULLIF(NULLIF(CAST(p.MEMBER_PLAN_END_DATE AS date),'3000-01-01'),'1800-01-01')
               ,full_scope_flag                = LEFT(p.IS_FULLSCOPE,1)
               ,share_of_cost_flag             = LEFT(p.IS_SOC,1)
               ,terminate_reason_name          = NULLIF(LTRIM(RTRIM(p.MEMBER_TERMINATE_REASON_NAME)),'')
               ,disenroll_reason               = NULLIF(LTRIM(RTRIM(p.DISENROLL_REASON)),'')
               ,source_member_version_key      = p.MEMBER_PLAN_SEL_HIST_FACT_KEY
        INTO    #span
        FROM    ODS_FINAL.dbo.MEMBER_PLAN_SELECTION p WITH (NOLOCK)
        WHERE   ISNULL(p.DELETED_FLAG,'') <> 'Y'
          AND   p.MEMBER_HCC_ID IS NOT NULL
          AND   p.BENEFIT_PLAN_HCC_ID IS NOT NULL
          AND   p.MEMBER_PLAN_START_DATE IS NOT NULL;

        CREATE CLUSTERED INDEX ix_stage_span ON #span
            (member_identifier, benefit_plan_identifier, member_benefit_plan_start_date);

        INSERT odm.enrollment_member WITH (TABLOCK)
            (member_identifier, last_name, first_name, middle_name, name_prefix, name_suffix,
             birth_date, death_date, gender_code, marital_status_code, medicare_status_code,
             native_american_alaskan_flag, member_status_code, hcp_number,
             enrollment_start_date, enrollment_end_date, ccs_flag,
             employment_status_code, source_member_version_key, insert_batch_id)
        SELECT s.member_identifier, s.last_name, s.first_name, s.middle_name, s.name_prefix, s.name_suffix,
               s.birth_date, s.death_date, s.gender_code, s.marital_status_code, s.medicare_status_code,
               s.native_american_alaskan_flag, s.member_status_code,
               CASE WHEN h.hcp_number IS NULL THEN NULL ELSE s.hcp_number END,   -- FK guard
               s.enrollment_start_date, s.enrollment_end_date, 'N',
               s.employment_status_code, s.source_member_version_key, @run
        FROM   #member s
        LEFT JOIN odm.enrollment_hcp h ON h.hcp_number = s.hcp_number;

        DECLARE @rows_member bigint = @@ROWCOUNT;

        INSERT odm.enrollment_benefit_plan_span WITH (TABLOCK)
            (member_identifier, benefit_plan_identifier, member_benefit_plan_start_date,
             member_benefit_plan_end_date, full_scope_flag, share_of_cost_flag,
             terminate_reason_name, disenroll_reason, source_member_version_key, insert_batch_id)
        SELECT s.member_identifier, s.benefit_plan_identifier, s.member_benefit_plan_start_date,
               MAX(s.member_benefit_plan_end_date), MAX(s.full_scope_flag), MAX(s.share_of_cost_flag),
               MAX(s.terminate_reason_name), MAX(s.disenroll_reason),
               MAX(s.source_member_version_key), @run
        FROM   #span s
        JOIN   odm.enrollment_member m ON m.member_identifier = s.member_identifier
        WHERE  (s.member_benefit_plan_end_date IS NULL
                OR s.member_benefit_plan_end_date >= s.member_benefit_plan_start_date)
        GROUP BY s.member_identifier, s.benefit_plan_identifier, s.member_benefit_plan_start_date;

        DECLARE @rows_span bigint = @@ROWCOUNT;

        EXEC ctl.usp_run_finish @run_member, @rows_member;
        EXEC ctl.usp_run_finish @run_span,   @rows_span;

        /* Publication moved out to pub.usp_publish_feed, 24 Sep. Its filters read slice 2 tables, which do not exist yet at this point. Run order: slice 1 -> slice 2 -> pub.usp_publish_feed. */

        /* a span ending on its start date carries no coverage. Counted here as an odm level
           observation; pub.usp_publish_feed is what excludes them from a file. */
        DECLARE @zero_day bigint = (SELECT COUNT_BIG(*) FROM odm.enrollment_benefit_plan_span
                                    WHERE member_benefit_plan_end_date = member_benefit_plan_start_date);

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SET @msg = LEFT(ERROR_MESSAGE(), 400);
        EXEC ctl.usp_run_fail @first_run, @msg;
        THROW;
    END CATCH

    /* how many members needed the pick rule */
    SELECT  members_with_more_than_one_current_version = @dups,
            rule_applied                 = 'kept the latest MEMBER_EFFECTIVE_DATE, tie broken by MEMBER_HISTORY_FACT_KEY',
            zero_day_spans_in_odm        = @zero_day;

    /* timing and row counts for this run */
    SELECT  entity_name,
            started_at,
            finished_at,
            seconds                 = DATEDIFF(second, started_at, finished_at),
            rows_loaded_count,
            rows_previous_run_count,
            pct_change,
            status_code
    FROM    ctl.load_run
    WHERE   run_identifier >= @first_run
    ORDER BY run_identifier;

    /* layer reconciliation. pub is not written here any more -- see pub.usp_publish_feed. */
    SELECT layer = '1 odm.enrollment_hcp',                 rows_found = COUNT_BIG(*) FROM odm.enrollment_hcp
    UNION ALL SELECT '2 odm.enrollment_member',            COUNT_BIG(*) FROM odm.enrollment_member
    UNION ALL SELECT '3 odm.enrollment_benefit_plan_span', COUNT_BIG(*) FROM odm.enrollment_benefit_plan_span;

    SELECT next_step = 'run odm.usp_load_slice_2, then pub.usp_publish_feed for each active feed';
END
GO


/* run it */
/* this file DEPLOYS the procedure. it does not run it.
   copy one of these into your own window to run the load. */

-- EXEC odm.usp_load_slice_1 @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M', @row_limit = 10000;   -- small, for timings
-- EXEC odm.usp_load_slice_1 @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M';                       -- full
GO
