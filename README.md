USE [ODM];
GO
ALTER TABLE cfg.publication_feed ADD exclude_duplicate_flag    char(1)      NULL;
ALTER TABLE cfg.publication_feed ADD exclude_hcp_list          varchar(200) NULL;
ALTER TABLE cfg.publication_feed ADD require_cin_extended_flag char(1)      NULL;
ALTER TABLE cfg.publication_feed ADD exclude_benefit_plan_list varchar(200) NULL;
GO
SELECT name FROM sys.columns
WHERE  object_id = OBJECT_ID('cfg.publication_feed')
  AND  name IN ('exclude_duplicate_flag','exclude_hcp_list',
                'require_cin_extended_flag','exclude_benefit_plan_list');
 
USE [ODM];
GO
ALTER TABLE cfg.publication_feed WITH CHECK ADD CONSTRAINT ck_feed_excl_dup
    CHECK (exclude_duplicate_flag IS NULL OR exclude_duplicate_flag IN ('Y','N'));
ALTER TABLE cfg.publication_feed WITH CHECK ADD CONSTRAINT ck_feed_req_cin_ext
    CHECK (require_cin_extended_flag IS NULL OR require_cin_extended_flag IN ('Y','N'));
GO
SELECT constraint_name = name, allowed = OBJECT_DEFINITION(object_id)
FROM   sys.check_constraints
WHERE  parent_object_id = OBJECT_ID('cfg.publication_feed')
  AND  OBJECT_DEFINITION(object_id) LIKE '%span_policy%';


UPDATE cfg.publication_feed
SET    eligibility_timeframe_count     = 15,
       eligibility_timeframe_qualifier = 'MONTH',
       span_policy                     = 'ALL_QUALIFYING_SPANS',
       exclude_duplicate_flag          = 'Y',
       exclude_hcp_list                = '956',
       require_cin_extended_flag       = 'Y',
       exclude_benefit_plan_list       = 'WR001,WR002',
       last_changed_date               = CAST(GETDATE() AS date),
       last_changed_by                 = 'RK 24Sep2026'
WHERE  feed_code = 'NORTHBAY_M';
