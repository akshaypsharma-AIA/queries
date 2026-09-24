USE [ODM];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('cfg.publication_feed','exclude_duplicate_flag') IS NULL
    ALTER TABLE cfg.publication_feed ADD exclude_duplicate_flag char(1) NULL;
GO
IF COL_LENGTH('cfg.publication_feed','exclude_hcp_list') IS NULL
    ALTER TABLE cfg.publication_feed ADD exclude_hcp_list varchar(200) NULL;
GO
IF COL_LENGTH('cfg.publication_feed','require_cin_extended_flag') IS NULL
    ALTER TABLE cfg.publication_feed ADD require_cin_extended_flag char(1) NULL;
GO
IF COL_LENGTH('cfg.publication_feed','exclude_benefit_plan_list') IS NULL
    ALTER TABLE cfg.publication_feed ADD exclude_benefit_plan_list varchar(200) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_feed_excl_dup')
    ALTER TABLE cfg.publication_feed WITH CHECK ADD CONSTRAINT ck_feed_excl_dup
        CHECK (exclude_duplicate_flag IS NULL OR exclude_duplicate_flag IN ('Y','N'));

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_feed_req_cin_ext')
    ALTER TABLE cfg.publication_feed WITH CHECK ADD CONSTRAINT ck_feed_req_cin_ext
        CHECK (require_cin_extended_flag IS NULL OR require_cin_extended_flag IN ('Y','N'));
GO

SELECT  constraint_name = name, allowed = OBJECT_DEFINITION(object_id)
FROM    sys.check_constraints
WHERE   parent_object_id = OBJECT_ID('cfg.publication_feed')
  AND   OBJECT_DEFINITION(object_id) LIKE '%span_policy%';
GO

UPDATE  cfg.publication_feed
SET     eligibility_timeframe_count     = 15,
        eligibility_timeframe_qualifier = 'MONTH',
        span_policy                     = 'ALL_QUALIFYING_SPANS',
        exclude_duplicate_flag          = 'Y',
        exclude_hcp_list                = '956',
        require_cin_extended_flag       = 'Y',
        exclude_benefit_plan_list       = 'WR001,WR002',
        last_changed_date               = CAST(GETDATE() AS date),
        last_changed_by                 = 'RK 24Sep2026'
WHERE   feed_code = 'NORTHBAY_M';
GO

SELECT  feed_code, span_policy,
        eligibility_timeframe_count, eligibility_timeframe_qualifier,
        eligibility_date_source, capitation_network_scope,
        member_status_filter,
        exclude_newborn_flag, exclude_duplicate_flag, require_cin_extended_flag,
        exclude_hcp_list, exclude_benefit_plan_list, exclude_wellrec_only_flag,
        last_changed_by
FROM    cfg.publication_feed
WHERE   feed_code = 'NORTHBAY_M';
GO
