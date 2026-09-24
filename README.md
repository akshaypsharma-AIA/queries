DECLARE @run int, @first_run int, @rows bigint, @msg nvarchar(2048);

/* ---- the configuration. Every filter below reads from here, never from a literal. ---- */
DECLARE @span_policy        varchar(20),
        @date_source        varchar(20),
        @lookback_count     int,
        @lookback_qualifier varchar(10),
        @status_filter      varchar(20),
        @county_filter      varchar(200),
        @plan_filter        varchar(200),
        @network_scope      varchar(200),
        @supplier_scope     varchar(200),
        @direct_members     char(1),
        @excl_deceased      char(1),
        @excl_newborn       char(1),
        @excl_non_full      char(1),
        @excl_unmet_soc     char(1),
        @excl_wellrec_only  char(1),
        @wellrec_county_exc varchar(200),
        @file_type          varchar(10),
        @maintenance_type   char(3),
        @lookback_from      date;

SET @reference_date = ISNULL(@reference_date, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));

BEGIN TRY

    /* ================= pre-flight ================= */

    SELECT  @span_policy        = span_policy,
            @date_source        = eligibility_date_source,
            @lookback_count     = eligibility_timeframe_count,
            @lookback_qualifier = eligibility_timeframe_qualifier,
            @status_filter      = member_status_filter,
            @county_filter      = county_filter,
            @plan_filter        = benefit_plan_filter,
            @network_scope      = capitation_network_scope,
            @supplier_scope     = capitation_supplier_scope,
            @direct_members     = include_direct_members_flag,
            @excl_deceased      = exclude_deceased_flag,
            @excl_newborn       = exclude_newborn_flag,
            @excl_non_full      = exclude_non_full_scope_flag,
            @excl_unmet_soc     = exclude_unmet_soc_flag,
            @excl_wellrec_only  = exclude_wellrec_only_flag,
            @wellrec_county_exc = wellrec_county_exception,
            @file_type          = file_type
    FROM    cfg.publication_feed
    WHERE   feed_code = @feed_code AND active_flag = 'Y';

    IF @@ROWCOUNT = 0
        THROW 50020, 'No active cfg.publication_feed row for that feed_code.', 1;

    IF NOT EXISTS (SELECT 1 FROM odm.enrollment_benefit_plan_span)
        THROW 50021, 'odm.enrollment_benefit_plan_span is empty. Run slice 1 first.', 1;

    IF NOT EXISTS (SELECT 1 FROM odm.enrollment_provider)
        THROW 50022, 'odm.enrollment_provider is empty. Run slice 2 first.', 1;

    IF @reference_date < '2026-08-01' OR @reference_date >= '2028-01-01'
        THROW 50002, 'reference_date is outside pf_publication_run_date.', 1;

    UPDATE ctl.load_run
    SET    status_code = 'ABANDONED', finished_at = SYSDATETIME(),
           halt_reason = 'No completion recorded. Session terminated.'
    WHERE  status_code = 'RUNNING' AND started_at <= DATEADD(hour, -@stale_hours, SYSDATETIME());

    IF EXISTS (SELECT 1 FROM ctl.load_run WHERE status_code = 'RUNNING')
        THROW 50005, 'Another load is already running.', 1;

    SET @first_run = ISNULL((SELECT MAX(run_identifier) FROM ctl.load_run), 0) + 1;

    /* INS03 and HD01. Constant 030 on a full file. */
    SET @maintenance_type = CASE WHEN @file_type = 'FULL' THEN '030' END;

    /* the look back window. Applies to the END date: a member whose coverage ended inside
       the window is still sent. */
    SET @lookback_from = CASE
          WHEN @lookback_qualifier = 'DAY'   THEN DATEADD(day,   -@lookback_count, @reference_date)
          WHEN @lookback_qualifier = 'MONTH' THEN DATEADD(month, -@lookback_count, @reference_date)
          WHEN @lookback_qualifier = 'YEAR'  THEN DATEADD(year,  -@lookback_count, @reference_date)
          ELSE @reference_date END;

    /* comma lists are matched by wrapping both sides in commas, so 'a' cannot match 'at' */
    DECLARE @status_list  varchar(24)  = ',' + REPLACE(ISNULL(@status_filter,''),' ','')  + ',';
    DECLARE @county_list  varchar(204) = ',' + REPLACE(ISNULL(@county_filter,''),' ','')  + ',';
    DECLARE @plan_list    varchar(204) = ',' + REPLACE(ISNULL(@plan_filter,''),' ','')    + ',';
    DECLARE @network_list varchar(204) = ',' + REPLACE(ISNULL(@network_scope,''),' ','')  + ',';
    DECLARE @supplier_list varchar(204)= ',' + REPLACE(ISNULL(@supplier_scope,''),' ','') + ',';
    DECLARE @wrexc_list   varchar(204) = ',' + REPLACE(ISNULL(@wellrec_county_exc,''),' ','') + ',';


    /* ================= empty this feed, children before parent ================= */

    DELETE pub.member_language
    WHERE  reference_date = @reference_date AND feed_code = @feed_code;
    DELETE pub.member_other_insurance
    WHERE  reference_date = @reference_date AND feed_code = @feed_code;
    DELETE pub.member_benefit_plan_span
    WHERE  reference_date = @reference_date AND feed_code = @feed_code;


    /* ==================================================================================
       STAGE 1. The qualifying population.
       Every filter is driven by cfg.publication_feed. A NULL or empty value means the
       filter does not apply, which is why each test is written as "config is empty OR
       the row matches".
       ================================================================================== */

    EXEC ctl.usp_run_start 'pub.stage.population', @reference_date, @feed_code, @run OUTPUT;

    DROP TABLE IF EXISTS #pop;

    SELECT   s.member_identifier
            ,s.benefit_plan_identifier
            ,s.member_benefit_plan_start_date
            ,s.member_benefit_plan_end_date
            ,s.aid_code
            ,s.full_scope_flag
            ,s.share_of_cost_flag
            ,s.source_member_version_key

            /* the coverage dates the file will carry. PLAN uses the benefit plan span;
               anything else uses the matching provider relationship, which for NorthBay
               is the hospital capitation window. */
            ,pub_start_date = CASE WHEN @date_source = 'PLAN'
                                   THEN s.member_benefit_plan_start_date
                                   ELSE p.effective_date END
            ,pub_end_date   = CASE WHEN @date_source = 'PLAN'
                                   THEN s.member_benefit_plan_end_date
                                   ELSE p.expiration_date END

            /* direct member: no PCP at all, or a PCP at a pseudo location.
               Outbound Matrix, Selection Flag Logics tab. */
            ,direct_member_flag = CASE WHEN pcp.member_identifier IS NULL
                                        OR pcp.supplier_location_identifier LIKE 'Pseudo%'
                                       THEN 'Y' ELSE 'N' END

            /* wellrec scope. ONLY when the COUNTY PROGRAM is Wellness and Recovery, so it
               is the member's whole benefit. BOTH when the COUNTY PROGRAM is Medi-Cal and
               they also hold Wellness and Recovery as a COMPLIANCE PROGRAM. */
            ,wellrec_scope = CASE
                   WHEN h.county_program_name LIKE '%Wellness and Recovery%' THEN 'ONLY'
                   WHEN cp.member_identifier IS NOT NULL                     THEN 'BOTH'
                   ELSE 'NONE' END

            ,county_2char = a.county_2char_code

            ,rn = ROW_NUMBER() OVER (PARTITION BY s.member_identifier
                                     ORDER BY s.member_benefit_plan_start_date DESC,
                                              s.benefit_plan_identifier)
    INTO     #pop
    FROM     odm.enrollment_benefit_plan_span s
    JOIN     odm.enrollment_member m
          ON m.member_identifier = s.member_identifier

    /* the relationship that scopes this feed to one partner, and supplies the dates */
    LEFT JOIN odm.enrollment_provider p
          ON  p.member_identifier     = s.member_identifier
          AND p.provider_relationship = @date_source

    /* PCP, for the direct member test. Always PCP regardless of the date source. */
    LEFT JOIN odm.enrollment_provider pcp
          ON  pcp.member_identifier     = s.member_identifier
          AND pcp.provider_relationship = 'PCP'

    LEFT JOIN odm.enrollment_hcp h
          ON  h.hcp_number = m.hcp_number

    LEFT JOIN odm.enrollment_compliance_program cp
          ON  cp.member_identifier = s.member_identifier
          AND cp.compliance_program_name LIKE '%Wellness and Recovery%'

    LEFT JOIN odm.enrollment_address a
          ON  a.member_identifier   = s.member_identifier
          AND a.address_type_name   = 'Residential'
          AND a.address_type        = ''

    LEFT JOIN odm.enrollment_member_attribute nb
          ON  nb.member_identifier = s.member_identifier
          AND nb.attribute_name    = 'Newborn'

    WHERE
          /* --- the span carries coverage. A zero day span is a voided record. --- */
          (s.member_benefit_plan_end_date IS NULL
           OR s.member_benefit_plan_end_date > s.member_benefit_plan_start_date)

          /* --- live on the reference date, or ended inside the look back --- */
      AND  s.member_benefit_plan_start_date <= @reference_date
      AND (s.member_benefit_plan_end_date IS NULL
           OR s.member_benefit_plan_end_date >  @reference_date
           OR s.member_benefit_plan_end_date >= @lookback_from)

          /* --- member_status_filter --- */
      AND (@status_filter IS NULL OR @status_list LIKE '%,' + m.member_status_code + ',%')

          /* --- county_filter --- */
      AND (@county_filter IS NULL OR @county_list LIKE '%,' + a.county_2char_code + ',%')

          /* --- benefit_plan_filter --- */
      AND (@plan_filter IS NULL OR @plan_list LIKE '%,' + s.benefit_plan_identifier + ',%')

          /* --- capitation_network_scope. The filter that makes this one partner's file. --- */
      AND (@network_scope IS NULL
           OR @network_list LIKE '%,' + p.supplier_network_identifier + ',%')

          /* --- capitation_supplier_scope --- */
      AND (@supplier_scope IS NULL
           OR @supplier_list LIKE '%,' + p.supplier_identifier + ',%')

          /* --- exclude_deceased_flag --- */
      AND (@excl_deceased <> 'Y' OR m.death_date IS NULL)

          /* --- exclude_newborn_flag. The source is mixed case, so compare upper. --- */
      AND (@excl_newborn <> 'Y' OR UPPER(ISNULL(nb.attribute_value,'FALSE')) <> 'TRUE')

          /* --- exclude_non_full_scope_flag --- */
      AND (@excl_non_full <> 'Y' OR s.benefit_plan_identifier = 'MCAL001')

          /* --- exclude_unmet_soc_flag --- */
      AND (@excl_unmet_soc <> 'Y' OR s.benefit_plan_identifier NOT IN ('MCAL011','WR002'))

          /* --- exclude_wellrec_only_flag, unless the county is an exception --- */
      AND (@excl_wellrec_only <> 'Y'
           OR h.county_program_name NOT LIKE '%Wellness and Recovery%'
           OR h.county_program_name IS NULL
           OR (@wellrec_county_exc IS NOT NULL
               AND @wrexc_list LIKE '%,' + a.county_2char_code + ',%'))

          /* --- include_direct_members_flag. Y all, N none, O only direct members. --- */
      AND (@direct_members = 'Y'
           OR (@direct_members = 'N'
               AND pcp.member_identifier IS NOT NULL
               AND pcp.supplier_location_identifier NOT LIKE 'Pseudo%')
           OR (@direct_members = 'O'
               AND (pcp.member_identifier IS NULL
                    OR pcp.supplier_location_identifier LIKE 'Pseudo%')));

    SET @rows = @@ROWCOUNT;
    EXEC ctl.usp_run_finish @run, @rows;

    /* span_policy. MOST_RECENT_SPAN keeps one INS per member, the latest span.
       ALL_QUALIFYING_SPANS keeps every qualifying span, one INS each. */
    IF @span_policy = 'MOST_RECENT_SPAN'
        DELETE FROM #pop WHERE rn > 1;

    CREATE CLUSTERED INDEX ix_pop ON #pop (member_identifier);


    /* ==================================================================================
       STAGE 2. pub.member_benefit_plan_span
       ================================================================================== */

    EXEC ctl.usp_run_start 'pub.member_benefit_plan_span', @reference_date, @feed_code, @run OUTPUT;

    INSERT pub.member_benefit_plan_span WITH (TABLOCK)
        (reference_date, feed_code, member_identifier, benefit_plan_identifier,
         member_benefit_plan_start_date, member_benefit_plan_end_date,
         member_status_code, medicare_status_code, maintenance_type_code,
         cin_identifier, aid_code, afs_format_code,
         last_name, first_name, middle_name, name_prefix, name_suffix,
         birth_date, death_date, gender_code, primary_ethnicity_code,
         native_american_alaskan_flag,
         address_line_1_text, address_line_2_text, city_name, state_code, zip_code,
         county_code,
         mailing_address_line_1_text, mailing_address_line_2_text,
         mailing_city_name, mailing_state_code, mailing_zip_code,
         phone_number, hcp_number, full_scope_flag, share_of_cost_flag,
         ccs_flag, ccs_start_date, ccs_end_date,
         pcp_organisation_name, pcp_npi,
         pcp_address_line_1_text, pcp_address_line_2_text,
         pcp_city_name, pcp_state_code, pcp_zip_code, pcp_phone_number,
         employment_status_code, direct_member_flag, wellrec_scope,
         source_member_version_key, insert_batch_id)
    SELECT  @reference_date, @feed_code, x.member_identifier, x.benefit_plan_identifier,
            x.pub_start_date,
            DATEADD(day, -1, x.pub_end_date),          -- exclusive becomes inclusive, ONCE, here
            'A',                                        -- INS05 is a constant for PHC
            m.medicare_status_code, @maintenance_type,
            cin.identification_number,
            x.aid_code, m.afs_format_code,
            LEFT(m.last_name,60), LEFT(m.first_name,35), LEFT(m.middle_name,25),
            LEFT(m.name_prefix,10), LEFT(m.name_suffix,10),
            m.birth_date, m.death_date, m.gender_code,
            LEFT(eth.ethnicity_code,10), m.native_american_alaskan_flag,
            LEFT(res.address_line_1_text,55), LEFT(res.address_line_2_text,55),
            LEFT(res.city_name,30), res.state_code, LEFT(res.zip_code,5),
            res.county_2char_code,
            LEFT(mail.address_line_1_text,55), LEFT(mail.address_line_2_text,55),
            LEFT(mail.city_name,30), mail.state_code, LEFT(mail.zip_code,5),
            LEFT(ph.phone_area_code + ph.phone_number,20),
            m.hcp_number, x.full_scope_flag, ISNULL(x.share_of_cost_flag,'N'),
            m.ccs_flag, m.ccs_start_date, m.ccs_end_date,
            LEFT(pcp.provider_organisation_name,60), pcp.provider_npi,
            LEFT(pcp.provider_address_line_1_text,55), LEFT(pcp.provider_address_line_2_text,55),
            LEFT(pcp.provider_city_name,30), pcp.provider_state_code,
            LEFT(pcp.provider_zip_code,5), LEFT(pcp.provider_phone_number,20),
            m.employment_status_code, x.direct_member_flag, x.wellrec_scope,
            x.source_member_version_key, @run
    FROM    #pop x
    JOIN    odm.enrollment_member m ON m.member_identifier = x.member_identifier

    LEFT JOIN odm.enrollment_identifier cin
           ON  cin.member_identifier = x.member_identifier
           AND cin.id_type_code      = 'IT002'
           AND cin.effective_start_date = (SELECT MAX(c2.effective_start_date)
                                           FROM   odm.enrollment_identifier c2
                                           WHERE  c2.member_identifier = x.member_identifier
                                             AND  c2.id_type_code = 'IT002')

    LEFT JOIN odm.enrollment_ethnicity eth
           ON  eth.member_identifier = x.member_identifier

    LEFT JOIN odm.enrollment_address res
           ON  res.member_identifier = x.member_identifier
           AND res.address_type_name = 'Residential'
           AND res.address_type      = ''

    LEFT JOIN odm.enrollment_address mail
           ON  mail.member_identifier = x.member_identifier
           AND mail.address_type_name = 'Correspondence Override'
           AND mail.address_type      = ''

    /* PER04 takes one number. Home first, then mobile, then work. */
    LEFT JOIN (SELECT member_identifier, phone_area_code, phone_number,
                      rn = ROW_NUMBER() OVER (PARTITION BY member_identifier
                             ORDER BY CASE phone_type_name
                                        WHEN 'Home phone number' THEN 1
                                        WHEN 'Mobile'            THEN 2
                                        WHEN 'Work Phone Number' THEN 3
                                        ELSE 4 END)
               FROM   odm.enrollment_contact) ph
           ON  ph.member_identifier = x.member_identifier AND ph.rn = 1

    LEFT JOIN odm.enrollment_provider pcp
           ON  pcp.member_identifier     = x.member_identifier
           AND pcp.provider_relationship = 'PCP';

    SET @rows = @@ROWCOUNT;
    EXEC ctl.usp_run_finish @run, @rows;


    /* ==================================================================================
       STAGE 3. pub.member_language
       One language per use per member. 6 is written, 7 is spoken, per Nelson 9/20.
       ================================================================================== */

    EXEC ctl.usp_run_start 'pub.member_language', @reference_date, @feed_code, @run OUTPUT;

    INSERT pub.member_language WITH (TABLOCK)
        (reference_date, feed_code, member_identifier, benefit_plan_identifier,
         member_benefit_plan_start_date, language_use_indicator, language_code,
         source_member_version_key, insert_batch_id)
    SELECT  s.reference_date, s.feed_code, s.member_identifier, s.benefit_plan_identifier,
            s.member_benefit_plan_start_date,
            CASE l.language_use WHEN 'SPOKEN' THEN '7' WHEN 'WRITTEN' THEN '6' END,
            NULLIF(LTRIM(RTRIM(x.LANG_X12_CODE)),''),
            l.source_member_version_key, @run
    FROM    pub.member_benefit_plan_span s
    JOIN   (SELECT  member_identifier, language_use, language_code, source_member_version_key,
                    rn = ROW_NUMBER() OVER (PARTITION BY member_identifier, language_use
                                            ORDER BY priority, language_code)
            FROM    odm.enrollment_language) l
           ON  l.member_identifier = s.member_identifier AND l.rn = 1
    LEFT JOIN (SELECT LANG_DESCRIPTION, LANG_X12_CODE = MIN(LANG_X12_CODE)
               FROM   ODS_FINAL.XWALK.INT_LANGUAGE_XWALK
               WHERE  END_DATE > GETDATE()
                 AND  NULLIF(LTRIM(RTRIM(LANG_X12_CODE)),'') IS NOT NULL
               GROUP BY LANG_DESCRIPTION) x
           ON x.LANG_DESCRIPTION = l.language_code
    WHERE   s.reference_date = @reference_date AND s.feed_code = @feed_code;

    SET @rows = @@ROWCOUNT;
    EXEC ctl.usp_run_finish @run, @rows;


    /* ==================================================================================
       STAGE 4. pub.member_other_insurance
       Loop 2320 repeats at most 5 times, the 5 most recent by termination date.
       CG p18, TR3 p164. COB01 is P, COB03 is 1.
       ================================================================================== */

    EXEC ctl.usp_run_start 'pub.member_other_insurance', @reference_date, @feed_code, @run OUTPUT;

    INSERT pub.member_other_insurance WITH (TABLOCK)
        (reference_date, feed_code, member_identifier, benefit_plan_identifier,
         member_benefit_plan_start_date, carrier_sequence,
         payer_responsibility_code, cob_policy_identifier, coordination_of_benefits_code,
         coverage_scope_code, cob_effective_date, cob_termination_date,
         carrier_name, source_member_version_key, insert_batch_id)
    SELECT  s.reference_date, s.feed_code, s.member_identifier, s.benefit_plan_identifier,
            s.member_benefit_plan_start_date, CAST(k.rk AS tinyint),
            'P', LEFT(CAST(k.cob_policy_identifier AS varchar(50)),50), '1',
            k.coverage_scope_code, k.effective_date, k.termination_date,
            LEFT(k.carrier_name,60), k.source_member_version_key, @run
    FROM    pub.member_benefit_plan_span s
    JOIN   (SELECT  o.*,
                    rk = ROW_NUMBER() OVER (
                           PARTITION BY o.member_identifier
                           ORDER BY CASE WHEN o.termination_date IS NULL THEN 0 ELSE 1 END,
                                    o.termination_date DESC,
                                    o.cob_policy_identifier DESC)
            FROM    odm.enrollment_other_insurance o) k
           ON k.member_identifier = s.member_identifier AND k.rk <= 5
    WHERE   s.reference_date = @reference_date AND s.feed_code = @feed_code;

    SET @rows = @@ROWCOUNT;
    EXEC ctl.usp_run_finish @run, @rows;

    /* cob_carrier_count must equal the loops published, or it lies */
    UPDATE  s
    SET     s.cob_carrier_count = c.n
    FROM    pub.member_benefit_plan_span s
    JOIN   (SELECT reference_date, feed_code, member_identifier,
                   benefit_plan_identifier, member_benefit_plan_start_date, n = COUNT(*)
            FROM   pub.member_other_insurance
            WHERE  reference_date = @reference_date AND feed_code = @feed_code
            GROUP BY reference_date, feed_code, member_identifier,
                     benefit_plan_identifier, member_benefit_plan_start_date) c
           ON  c.reference_date = s.reference_date AND c.feed_code = s.feed_code
           AND c.member_identifier = s.member_identifier
           AND c.benefit_plan_identifier = s.benefit_plan_identifier
           AND c.member_benefit_plan_start_date = s.member_benefit_plan_start_date
    WHERE   s.reference_date = @reference_date AND s.feed_code = @feed_code;

END TRY
BEGIN CATCH
    SET @msg = ERROR_MESSAGE();
    EXEC ctl.usp_run_fail @first_run, @msg;
    THROW;
END CATCH
