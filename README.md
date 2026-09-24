USE [ODM];
UPDATE cfg.publication_feed SET eligibility_date_source = 'Hosp' WHERE feed_code = 'NORTHBAY_M';
GO
EXEC pub.usp_publish_feed @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M';
GO
SELECT rows_published = COUNT(*), members = COUNT(DISTINCT member_identifier)
FROM   pub.member_benefit_plan_span
WHERE  reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';
