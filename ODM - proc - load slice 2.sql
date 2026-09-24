/* 834 outbound -- slice 2. The nine odm satellites and the two pub children. Runs after odm.usp_load_slice_1. */

USE [ODM];
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE odm.usp_load_slice_2
    @reference_date date        = NULL,
    @feed_code      varchar(30) = 'NORTHBAY_M',
    @as_of          date        = NULL,
    @stale_hours    int         = 4
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run int, @first_run int, @rows bigint, @dups bigint, @msg nvarchar(2048);

    /* ODS_FINAL uses 1800-01-01, 2999-01-01 and 3000-01-01 to mean no date. Test a range, not a list -- a new sentinel would slip past a list. */
    DECLARE @date_low date = '1900-01-01', @date_high date = '2100-01-01';

    SET @reference_date = ISNULL(@reference_date, DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1));
    SET @as_of          = ISNULL(@as_of, CAST(GETDATE() AS date));

    BEGIN TRY

        /* ========== pre-flight ========== */

        IF NOT EXISTS (SELECT 1 FROM cfg.publication_feed WHERE feed_code = @feed_code)
            THROW 50001, 'No cfg.publication_feed row for that feed_code.', 1;

        IF NOT EXISTS (SELECT 1 FROM odm.enrollment_member)
            THROW 50010, 'odm.enrollment_member is empty. Run slice 1 first.', 1;

        UPDATE ctl.load_run
        SET    status_code = 'ABANDONED', finished_at = SYSDATETIME(),
               halt_reason = 'No completion recorded. Session terminated.'
        WHERE  status_code = 'RUNNING' AND started_at <= DATEADD(hour, -@stale_hours, SYSDATETIME());

        IF EXISTS (SELECT 1 FROM ctl.load_run WHERE status_code = 'RUNNING')
            THROW 50005, 'Another load is already running.', 1;

        SET @first_run = ISNULL((SELECT MAX(run_identifier) FROM ctl.load_run), 0) + 1;

        /* ========== empty the targets, children before parents ========== */

        DELETE odm.enrollment_other_insurance;
        DELETE odm.enrollment_compliance_program;
        DELETE odm.enrollment_member_attribute;
        DELETE odm.enrollment_provider;
        DELETE odm.enrollment_contact;
        DELETE odm.enrollment_identifier;
        DELETE odm.enrollment_ethnicity;
        DELETE odm.enrollment_language;
        DELETE odm.enrollment_address;


        /* 1  odm.enrollment_address. A single hyphen is PHC's placeholder for unknown and becomes NULL. address_type is NOT NULL in the key; the empty string is the default. */

        EXEC ctl.usp_run_start 'odm.enrollment_address', @reference_date, NULL, @run OUTPUT;

        DROP TABLE IF EXISTS #addr;
        SELECT   member_identifier   = LTRIM(RTRIM(a.MEMBER_HCC_ID))
                ,address_type_name   = ISNULL(NULLIF(LTRIM(RTRIM(a.MEMBER_ADDRESS_TYPE_NAME)),''),'UNKNOWN')
                ,address_type        = CASE WHEN LTRIM(RTRIM(ISNULL(a.ADDRESS_TYPE,''))) = 'PO Box Address'
                                            THEN 'PO Box Address' ELSE '' END
                ,rec_type            = LEFT(a.REC_TYPE,50)
                ,address_line_1_text = NULLIF(LTRIM(RTRIM(a.ADDRESS_LINE)),'')
                ,address_line_2_text = NULLIF(LTRIM(RTRIM(a.ADDRESS_LINE_2)),'')
                ,address_line_3_text = NULLIF(LTRIM(RTRIM(a.ADDRESS_LINE_3)),'')
                ,city_name           = NULLIF(LTRIM(RTRIM(a.CITY_NAME)),'')
                ,state_code          = CASE WHEN LEN(LTRIM(RTRIM(a.STATE_CODE))) = 2
                                            THEN LTRIM(RTRIM(a.STATE_CODE)) END
                ,zip_code            = NULLIF(NULLIF(LTRIM(RTRIM(a.ZIP_CODE)),''),'-')
                ,zip_plus4           = NULLIF(LTRIM(RTRIM(a.ZIP_4_CODE)),'')
                ,county_fips_code    = NULLIF(NULLIF(LTRIM(RTRIM(a.COUNTY_CODE)),''),'-')
                ,country_code        = NULLIF(LTRIM(RTRIM(a.COUNTRY_CODE)),'')
                ,effective_date      = CASE WHEN a.EFF_DATE BETWEEN @date_low AND @date_high
                                            THEN CAST(a.EFF_DATE AS date) END
                ,end_date            = CASE WHEN a.END_DATE BETWEEN @date_low AND @date_high
                                            THEN CAST(a.END_DATE AS date) END
                ,priority            = a.PRIORITY
                ,source_member_version_key = a.MEMBER_HISTORY_FACT_KEY
                ,address_oid         = a.ADDRESS_OID
                ,rn = ROW_NUMBER() OVER (
                        PARTITION BY a.MEMBER_HCC_ID,
                                     ISNULL(NULLIF(LTRIM(RTRIM(a.MEMBER_ADDRESS_TYPE_NAME)),''),'UNKNOWN'),
                                     CASE WHEN LTRIM(RTRIM(ISNULL(a.ADDRESS_TYPE,''))) = 'PO Box Address'
                                          THEN 'PO Box Address' ELSE '' END
                        ORDER BY a.PRIORITY, a.ADDRESS_OID DESC)
        INTO     #addr
        FROM     ODS_FINAL.dbo.ADDRESS a WITH (NOLOCK)
        JOIN     odm.enrollment_member m ON m.source_member_version_key = a.MEMBER_HISTORY_FACT_KEY
        WHERE    ISNULL(a.DELETED_FLAG,'') <> 'Y';

        /* 12 rows break the key -- lowest PRIORITY wins, then the newest row */
        INSERT odm.enrollment_address WITH (TABLOCK)
            (member_identifier, address_type_name, address_type, rec_type,
             address_line_1_text, address_line_2_text, address_line_3_text,
             city_name, state_code, zip_code, zip_plus4, county_fips_code, country_code,
             effective_date, end_date, priority,
             county_number, county_2char_code, source_member_version_key, insert_batch_id)
        SELECT  a.member_identifier, a.address_type_name, a.address_type, a.rec_type,
                a.address_line_1_text, a.address_line_2_text, a.address_line_3_text,
                a.city_name, a.state_code, a.zip_code, a.zip_plus4, a.county_fips_code, a.country_code,
                a.effective_date, a.end_date, a.priority,
                h.county_number, h.county_code, a.source_member_version_key, @run
        FROM    #addr a
        JOIN    odm.enrollment_member m ON m.member_identifier = a.member_identifier
        LEFT JOIN odm.enrollment_hcp h  ON h.hcp_number        = m.hcp_number
        WHERE   a.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 2  odm.enrollment_language. A source row carries SPOKEN_LANG or WRITTEN_LANG, never both. The name in SPOKEN_LANG is not reliable, so the language is resolved through LANGUAGE_DOMAIN_CODE against INT_LANGUAGE_XWALK. */

        EXEC ctl.usp_run_start 'odm.enrollment_language', @reference_date, NULL, @run OUTPUT;

        DROP TABLE IF EXISTS #lang;
        SELECT   member_identifier = LTRIM(RTRIM(l.MEMBER_HCC_ID))
                ,language_use      = CASE WHEN NULLIF(LTRIM(RTRIM(l.SPOKEN_LANG)),'') IS NOT NULL
                                          THEN 'SPOKEN' ELSE 'WRITTEN' END
                /* the crosswalk description wins; the raw name is the fallback */
                ,language_code     = LEFT(COALESCE(x.LANG_DESCRIPTION,
                                          NULLIF(LTRIM(RTRIM(l.SPOKEN_LANG)),''),
                                          NULLIF(LTRIM(RTRIM(l.WRITTEN_LANG)),'')),50)
                ,priority          = l.PRIORITY
                ,language_source   = LEFT(l.LANG_SOURCE,15)
                ,source_member_version_key = l.MEMBER_HISTORY_FACT_KEY
                ,language_oid      = l.LANGUAGE_OID
        INTO     #lang
        FROM     ODS_FINAL.dbo.[LANGUAGE] l WITH (NOLOCK)
        JOIN     odm.enrollment_member m ON m.source_member_version_key = l.MEMBER_HISTORY_FACT_KEY
        LEFT JOIN ODS_FINAL.XWALK.INT_LANGUAGE_XWALK x
               ON x.LANG_HRP_CODE = LTRIM(RTRIM(l.LANGUAGE_DOMAIN_CODE))
              AND x.END_DATE > GETDATE()
        WHERE    ISNULL(l.DELETED_FLAG,'') <> 'Y'
          AND    COALESCE(NULLIF(LTRIM(RTRIM(l.SPOKEN_LANG)),''),
                          NULLIF(LTRIM(RTRIM(l.WRITTEN_LANG)),'')) IS NOT NULL;

        INSERT odm.enrollment_language WITH (TABLOCK)
            (member_identifier, language_use, language_code, priority, language_source,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.language_use, x.language_code, x.priority, x.language_source,
                x.source_member_version_key, @run
        FROM   (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY member_identifier, language_use, language_code
                                                  ORDER BY priority, language_oid DESC)
                FROM #lang) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 3  odm.enrollment_ethnicity */

        EXEC ctl.usp_run_start 'odm.enrollment_ethnicity', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_ethnicity WITH (TABLOCK)
            (member_identifier, ethnicity_code, ethnicity_name, priority,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.ethnicity_code, x.ethnicity_name, x.priority,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier = LTRIM(RTRIM(e.MEMBER_HCC_ID))
                       ,ethnicity_code    = LTRIM(RTRIM(e.ETHNICITY_CODE))
                       ,ethnicity_name    = LEFT(e.ETHNICITY_NAME,50)
                       ,priority          = e.PRIORITY
                       ,source_member_version_key = e.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (PARTITION BY e.MEMBER_HCC_ID, e.ETHNICITY_CODE
                                                ORDER BY e.PRIORITY, e.ETHNICITY_OID DESC)
                FROM    ODS_FINAL.dbo.ETHNICITY e WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = e.MEMBER_HISTORY_FACT_KEY
                WHERE   ISNULL(e.DELETED_FLAG,'') <> 'Y'
                  AND   NULLIF(LTRIM(RTRIM(e.ETHNICITY_CODE)),'') IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 4  odm.enrollment_identifier. Types 2 and FI are excluded -- neither is a member identifier and both carry a NULL effective start date. */

        EXEC ctl.usp_run_start 'odm.enrollment_identifier', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_identifier WITH (TABLOCK)
            (member_identifier, id_type_code, effective_start_date, id_type_name,
             identification_number, effective_end_date, state_code, country_code,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.id_type_code, x.effective_start_date, x.id_type_name,
                x.identification_number, x.effective_end_date, x.state_code, x.country_code,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier     = LTRIM(RTRIM(o.MEMBER_HCC_ID))
                       ,id_type_code          = LTRIM(RTRIM(o.ID_TYPE_CODE))
                       ,effective_start_date  = CAST(o.EFFECTIVE_START_DATE AS date)   /* NOT NULL in the key, filtered below */
                       ,id_type_name          = LEFT(o.ID_TYPE_NAME,50)
                       ,identification_number = LTRIM(RTRIM(o.IDENTIFICATION_NUMBER))
                       ,effective_end_date    = CASE WHEN o.EFFECTIVE_END_DATE BETWEEN @date_low AND @date_high
                                                     THEN CAST(o.EFFECTIVE_END_DATE AS date) END
                       ,state_code            = NULLIF(LTRIM(RTRIM(o.STATE_CODE)),'')
                       ,country_code          = NULLIF(LTRIM(RTRIM(o.COUNTRY_CODE)),'')
                       ,source_member_version_key = o.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (
                               PARTITION BY o.MEMBER_HCC_ID, o.ID_TYPE_CODE,
                                            CAST(o.EFFECTIVE_START_DATE AS date)
                               ORDER BY o.MEMBER_OTHER_ID_OID DESC)
                FROM    ODS_FINAL.dbo.MEMBER_OTHER_ID o WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = o.MEMBER_HISTORY_FACT_KEY
                WHERE   ISNULL(o.DELETED_FLAG,'') <> 'Y'
                  AND   o.ID_TYPE_CODE LIKE 'IT%'
                  AND   o.EFFECTIVE_START_DATE IS NOT NULL
                  AND   NULLIF(LTRIM(RTRIM(o.IDENTIFICATION_NUMBER)),'') IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 5  odm.enrollment_contact. CONTACT_INFO is mostly not phones, so load only the rows carrying a number. */

        EXEC ctl.usp_run_start 'odm.enrollment_contact', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_contact WITH (TABLOCK)
            (member_identifier, phone_type_name, phone_country_code, phone_area_code,
             phone_number, phone_extension, email_address,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.phone_type_name, x.phone_country_code, x.phone_area_code,
                x.phone_number, x.phone_extension, x.email_address,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier  = LTRIM(RTRIM(c.MEMBER_HCC_ID))
                       ,phone_type_name    = LTRIM(RTRIM(c.PHONE_TYPE_NAME))
                       ,phone_country_code = NULLIF(LTRIM(RTRIM(c.PHONE_COUNTRY_CD)),'')
                       ,phone_area_code    = NULLIF(LTRIM(RTRIM(c.PHONE_AREA_CD)),'')
                       ,phone_number       = LTRIM(RTRIM(c.PHONE_NBR))
                       ,phone_extension    = NULLIF(LTRIM(RTRIM(c.PHONE_EXT_NBR)),'')
                       ,email_address      = NULLIF(LTRIM(RTRIM(c.CONTACT_INFO_EMAIL_ADDR_TXT)),'')
                       ,source_member_version_key = c.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (PARTITION BY c.MEMBER_HCC_ID, c.PHONE_TYPE_NAME
                                                ORDER BY c.CONTACT_INFO_OID DESC)
                FROM    ODS_FINAL.dbo.CONTACT_INFO c WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = c.MEMBER_HISTORY_FACT_KEY
                WHERE   ISNULL(c.DELETED_FLAG,'') <> 'Y'
                  AND   NULLIF(LTRIM(RTRIM(c.PHONE_NBR)),'')       IS NOT NULL
                  AND   NULLIF(LTRIM(RTRIM(c.PHONE_TYPE_NAME)),'') IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 6  odm.enrollment_provider. MEMBER_PROVIDER carries keys only -- name and NPI come from SUPPLIER, the address from ADDRESS on the supplier location fact key. */

        EXEC ctl.usp_run_start 'odm.enrollment_provider', @reference_date, NULL, @run OUTPUT;

        /* one practice address per supplier location; 11 locations of 139,605 hold two */
        DROP TABLE IF EXISTS #locaddr;
        SELECT   SUPPLIER_LOC_HIST_FACT_KEY
                ,address_line_1_text = NULLIF(LTRIM(RTRIM(ADDRESS_LINE)),'')
                ,address_line_2_text = NULLIF(LTRIM(RTRIM(ADDRESS_LINE_2)),'')
                ,city_name           = NULLIF(LTRIM(RTRIM(CITY_NAME)),'')
                ,state_code          = CASE WHEN LEN(LTRIM(RTRIM(STATE_CODE))) = 2
                                            THEN LTRIM(RTRIM(STATE_CODE)) END
                ,zip_code            = NULLIF(NULLIF(LTRIM(RTRIM(ZIP_CODE)),''),'-')
        INTO     #locaddr
        FROM    (SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY SUPPLIER_LOC_HIST_FACT_KEY
                                                   ORDER BY CASE WHEN ADDRESS_TYPE IS NULL THEN 0 ELSE 1 END,
                                                            ADDRESS_OID DESC)
                 FROM   ODS_FINAL.dbo.ADDRESS WITH (NOLOCK)
                 WHERE  ISNULL(DELETED_FLAG,'') <> 'Y'
                   AND  SUPPLIER_LOC_HIST_FACT_KEY IS NOT NULL
                   AND  REC_TYPE = 'SUPPLIER_LOCATION_PRACTICE') z
        WHERE    z.rn = 1;

        CREATE CLUSTERED INDEX ix_locaddr ON #locaddr (SUPPLIER_LOC_HIST_FACT_KEY);

        INSERT odm.enrollment_provider WITH (TABLOCK)
            (member_identifier, provider_relationship, effective_date, expiration_date,
             supplier_location_identifier, supplier_identifier, supplier_network_identifier,
             provider_organisation_name, provider_npi,
             provider_address_line_1_text, provider_address_line_2_text,
             provider_city_name, provider_state_code, provider_zip_code,
             provider_contact_name, provider_phone_number, provider_phone_extension,
             auto_assigned_flag, selection_reason_name,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.provider_relationship, x.effective_date, x.expiration_date,
                x.supplier_location_identifier, x.supplier_identifier, x.supplier_network_identifier,
                x.provider_organisation_name, x.provider_npi,
                x.address_line_1_text, x.address_line_2_text,
                x.city_name, x.state_code, x.zip_code,
                x.provider_contact_name, x.provider_phone_number, x.provider_phone_extension,
                x.auto_assigned_flag, x.selection_reason_name,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier     = LTRIM(RTRIM(p.MEMBER_HCC_ID))
                       ,provider_relationship = LEFT(LTRIM(RTRIM(p.MEMBER_PROVIDER_RELATIONSHIP)),50)
                       ,effective_date        = CAST(p.MEMBER_PROVIDER_EFFECTIVE_DATE AS date)
                       ,expiration_date       = CASE WHEN p.MEMBER_PROVIDER_EXPIRATION_DATE
                                                          BETWEEN @date_low AND @date_high
                                                     THEN CAST(p.MEMBER_PROVIDER_EXPIRATION_DATE AS date) END
                       ,supplier_location_identifier = NULLIF(LTRIM(RTRIM(p.SUPPLIER_LOCATION_HCC_ID)),'')
                       ,supplier_identifier          = NULLIF(LTRIM(RTRIM(p.SUPPLIER_HCC_ID)),'')
                       ,supplier_network_identifier  = NULLIF(LTRIM(RTRIM(p.SUPPLIER_NETWORK_HCC_ID)),'')
                       ,provider_organisation_name   = LEFT(s.SUPPLIER_NAME,150)
                       ,provider_npi                 = NULLIF(LTRIM(RTRIM(s.SUPPLIER_NPI)),'')
                       ,provider_contact_name        = LEFT(s.SUPPLIER_CONTACT_NAME,500)
                       ,provider_phone_number        = LEFT(NULLIF(LTRIM(RTRIM(s.TELEPHONE_NUMBER)),''),34)
                       ,provider_phone_extension     = LEFT(NULLIF(LTRIM(RTRIM(s.TELEPHONE_EXTENSION)),''),7)
                       ,auto_assigned_flag           = LEFT(p.AUTO_ASSIGNED,1)
                       ,selection_reason_name        = LEFT(p.PROVIDER_SELECTION_REASON_NAME,50)
                       ,la.address_line_1_text, la.address_line_2_text
                       ,la.city_name, la.state_code, la.zip_code
                       ,source_member_version_key = p.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (
                               PARTITION BY p.MEMBER_HCC_ID, p.MEMBER_PROVIDER_RELATIONSHIP,
                                            CAST(p.MEMBER_PROVIDER_EFFECTIVE_DATE AS date)
                               ORDER BY p.MEMBER_PROVIDER_OID DESC)
                FROM    ODS_FINAL.dbo.MEMBER_PROVIDER p WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = p.MEMBER_HISTORY_FACT_KEY
                LEFT JOIN ODS_FINAL.dbo.SUPPLIER s WITH (NOLOCK)
                       ON s.SUPPLIER_HCC_ID = p.SUPPLIER_HCC_ID
                      AND ISNULL(s.DELETED_FLAG,'') <> 'Y'
                      AND (s.VERSION_EXP_DATE > @as_of OR s.VERSION_EXP_DATE IS NULL)
                LEFT JOIN ODS_FINAL.dbo.SUPPLIER_LOCATION sl WITH (NOLOCK)
                       ON sl.SUPPLIER_LOCATION_HCC_ID = p.SUPPLIER_LOCATION_HCC_ID
                      AND ISNULL(sl.DELETED_FLAG,'') <> 'Y'
                      AND (sl.VERSION_EXP_DATE > @as_of OR sl.VERSION_EXP_DATE IS NULL)
                LEFT JOIN #locaddr la ON la.SUPPLIER_LOC_HIST_FACT_KEY = sl.SUPPLIER_LOC_HIST_FACT_KEY
                WHERE   ISNULL(p.DELETED_FLAG,'') <> 'Y'
                  AND   p.MEMBER_PROVIDER_CURRENT_FLAG = 'Y'
                  AND   p.MEMBER_PROVIDER_EFFECTIVE_DATE IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 7  odm.enrollment_member_attribute */

        EXEC ctl.usp_run_start 'odm.enrollment_member_attribute', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_member_attribute WITH (TABLOCK)
            (member_identifier, attribute_name, attribute_value, attribute_source,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.attribute_name, x.attribute_value, x.attribute_source,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier = LTRIM(RTRIM(u.MEMBER_HCC_ID))
                       ,attribute_name    = LEFT(LTRIM(RTRIM(u.UDT_ATTR_NAME)),150)
                       ,attribute_value   = NULLIF(LTRIM(RTRIM(u.UDT_ATTR_VALUE)),'')
                       ,attribute_source  = LEFT(u.UDT_NAME,20)
                       ,source_member_version_key = u.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (PARTITION BY u.MEMBER_HCC_ID, u.UDT_ATTR_NAME
                                                ORDER BY u.UDT_OID DESC)
                FROM    ODS_FINAL.dbo.UDT u WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = u.MEMBER_HISTORY_FACT_KEY
                WHERE   ISNULL(u.DELETED_FLAG,'') <> 'Y'
                  AND   NULLIF(LTRIM(RTRIM(u.UDT_ATTR_NAME)),'') IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 8  odm.enrollment_compliance_program. Version scoped, so the fact key. MEMBER_COMPL_PROG_CURRENT_FLAG is the currency control, not VERSION_EFF_DATE. */

        EXEC ctl.usp_run_start 'odm.enrollment_compliance_program', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_compliance_program WITH (TABLOCK)
            (member_identifier, compliance_program_name, effective_date, termination_date,
             priority, compliance_code, status_code, current_flag,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.program_name, x.effective_date, x.termination_date,
                x.priority, x.compliance_code, x.status_code, x.current_flag,
                x.source_member_version_key, @run
        FROM   (SELECT  member_identifier = LTRIM(RTRIM(g.MEMBER_HCC_ID))
                       ,program_name      = LEFT(LTRIM(RTRIM(g.PROGRAM_NAME)),255)
                       ,effective_date    = CAST(g.MEMBER_COMPL_PROG_EFF_DATE AS date)
                       ,termination_date  = CASE WHEN g.MEMBER_COMPL_PROG_TERM_DATE
                                                      BETWEEN @date_low AND @date_high
                                                 THEN CAST(g.MEMBER_COMPL_PROG_TERM_DATE AS date) END
                       ,priority          = TRY_CAST(g.PRIORITY AS int)
                       ,compliance_code   = NULLIF(LTRIM(RTRIM(g.COMPLIANCE_CODE)),'')
                       ,status_code       = NULLIF(LTRIM(RTRIM(g.COMPL_PROG_STATUS)),'')
                       ,current_flag      = LEFT(g.MEMBER_COMPL_PROG_CURRENT_FLAG,1)
                       ,source_member_version_key = g.MEMBER_HISTORY_FACT_KEY
                       ,rn = ROW_NUMBER() OVER (
                               PARTITION BY g.MEMBER_HCC_ID, g.PROGRAM_NAME,
                                            CAST(g.MEMBER_COMPL_PROG_EFF_DATE AS date)
                               ORDER BY g.COMPLIANCE_PROGRAM_OID DESC)
                FROM    ODS_FINAL.dbo.COMPLIANCE_PROGRAM g WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.source_member_version_key = g.MEMBER_HISTORY_FACT_KEY
                WHERE   ISNULL(g.DELETED_FLAG,'') <> 'Y'
                  AND   g.MEMBER_COMPL_PROG_CURRENT_FLAG = 'Y'
                  AND   g.MEMBER_COMPL_PROG_EFF_DATE IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;


        /* 9  odm.enrollment_other_insurance. The only table with no member fact key, so it joins on MEMBER_HCC_ID and takes the version window. Company name is carrier, carrier code and coverage scope, underscore delimited. */

        EXEC ctl.usp_run_start 'odm.enrollment_other_insurance', @reference_date, NULL, @run OUTPUT;

        INSERT odm.enrollment_other_insurance WITH (TABLOCK)
            (member_identifier, cob_policy_identifier, cob_span_sequence,
             carrier_name, carrier_code, coverage_scope_code, policy_alias_identifier,
             plan_identifier, plan_name, benefit_plan_type_code, priority_code,
             primary_payer_flag, secondary_payer_flag, effective_date, termination_date,
             subscriber_name, subscriber_birth_date, subscriber_gender_code,
             source_member_version_key, insert_batch_id)
        SELECT  x.member_identifier, x.cob_policy_identifier, x.seq,
                x.carrier_name, x.carrier_code, x.coverage_scope_code, x.policy_alias_identifier,
                x.plan_identifier, x.plan_name, x.benefit_plan_type_code, x.priority_code,
                x.primary_payer_flag, x.secondary_payer_flag, x.effective_date, x.termination_date,
                x.subscriber_name, x.subscriber_birth_date, x.subscriber_gender_code,
                NULL, @run
        FROM   (SELECT  member_identifier     = LTRIM(RTRIM(i.MEMBER_HCC_ID))
                       ,cob_policy_identifier = i.COB_POLICY_KEY
                       ,carrier_name          = LEFT(PARSENAME(REPLACE(i.OTHER_INSURANCE_COMPANY_NAME,'_','.'),3),107)
                       ,carrier_code          = LEFT(PARSENAME(REPLACE(i.OTHER_INSURANCE_COMPANY_NAME,'_','.'),2),4)
                       ,coverage_scope_code   = LEFT(PARSENAME(REPLACE(i.OTHER_INSURANCE_COMPANY_NAME,'_','.'),1),4)
                       ,policy_alias_identifier = LEFT(i.COB_POLICY_ID_ALIAS,300)
                       ,plan_identifier       = NULLIF(LTRIM(RTRIM(i.PLAN_ID)),'')
                       ,plan_name             = NULLIF(LTRIM(RTRIM(i.PLAN_NAME)),'')
                       ,benefit_plan_type_code= NULLIF(LTRIM(RTRIM(i.BENEFIT_PLAN_TYPE_CODE)),'')
                       ,priority_code         = LEFT(i.OTHER_INS_PRIORITY_CODE,2)
                       ,primary_payer_flag    = LEFT(i.IS_PRIMARY,1)
                       ,secondary_payer_flag  = LEFT(i.IS_SECONDARY,1)
                       /* ck_ohi_eff and ck_ohi_term take NULL or 1900-01-01 to 2100-01-01.
                          Anything outside that window is a sentinel, so it becomes NULL. */
                       ,effective_date        = CASE WHEN i.EFFECTIVE_DATE
                                                          BETWEEN @date_low AND @date_high
                                                     THEN CAST(i.EFFECTIVE_DATE AS date) END
                       ,termination_date      = CASE WHEN i.TERMINATION_DATE
                                                          BETWEEN @date_low AND @date_high
                                                     THEN CAST(i.TERMINATION_DATE AS date) END
                       ,subscriber_name       = LEFT(i.SUBSCRIBER_NAME,200)
                       ,subscriber_birth_date = CAST(i.SUBSCRIBER_DOB AS date)
                       ,subscriber_gender_code= LEFT(i.SUBSCRIBER_GENDER_CODE,1)
                       ,seq = CAST(ROW_NUMBER() OVER (
                                PARTITION BY i.MEMBER_HCC_ID, i.COB_POLICY_KEY
                                ORDER BY i.EFFECTIVE_DATE DESC, i.MEMBER_OTHER_INSURANCE_OID DESC)
                              AS tinyint)
                       ,rn  = ROW_NUMBER() OVER (
                                PARTITION BY i.MEMBER_HCC_ID, i.COB_POLICY_KEY
                                ORDER BY i.EFFECTIVE_DATE DESC, i.MEMBER_OTHER_INSURANCE_OID DESC)
                FROM    ODS_FINAL.dbo.MEMBER_OTHER_INSURANCE i WITH (NOLOCK)
                JOIN    odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(i.MEMBER_HCC_ID))
                WHERE   ISNULL(i.DELETED_FLAG,'') <> 'Y'
                  AND  (i.VERSION_EFF_DATE <= @as_of OR i.VERSION_EFF_DATE IS NULL)
                  AND  (i.VERSION_EXP_DATE >  @as_of OR i.VERSION_EXP_DATE IS NULL)
                  AND   i.OTHER_INSURANCE_COMPANY_NAME IS NOT NULL) x
        WHERE   x.rn = 1;

        SET @rows = @@ROWCOUNT;
        EXEC ctl.usp_run_finish @run, @rows;

    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        EXEC ctl.usp_run_fail @first_run, @msg;
        THROW;
    END CATCH
END
GO


/* Deploy only above this line. */

-- EXEC odm.usp_load_slice_2 @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M';

-- SELECT entity_name, rows_loaded_count, pct_change, status_code,
--        seconds = DATEDIFF(second, started_at, finished_at)
-- FROM   ctl.load_run WHERE run_identifier > (SELECT MAX(run_identifier) - 11 FROM ctl.load_run)
-- ORDER BY run_identifier;
GO
