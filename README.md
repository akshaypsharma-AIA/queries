USE [ODM];

SELECT rows_now = COUNT(*), members_now = COUNT(DISTINCT member_identifier)
FROM   pub.member_benefit_plan_span
WHERE  reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';

UPDATE cfg.publication_feed
SET    eligibility_date_source = 'PLAN'
WHERE  feed_code = 'NORTHBAY_M';

EXEC pub.usp_publish_feed @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M';

SELECT rows_plan = COUNT(*), members_plan = COUNT(DISTINCT member_identifier),
       per_member = CAST(COUNT(*)*1.0/NULLIF(COUNT(DISTINCT member_identifier),0) AS decimal(9,2))
FROM   pub.member_benefit_plan_span
WHERE  reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';
