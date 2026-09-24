/* One refresh, end to end. Slice 1 clears slice 2, so they always run together. */

USE [ODM];
GO

EXEC odm.usp_load_slice_1;
GO

EXEC odm.usp_load_slice_2;
GO

EXEC pub.usp_publish_feed @reference_date = '2026-09-01', @feed_code = 'NORTHBAY_M';
GO


/* ---- what ran ---- */

SELECT  entity_name, rows_loaded_count, pct_change, status_code,
        seconds = DATEDIFF(second, started_at, finished_at), halt_reason
FROM    ctl.load_run
WHERE   run_identifier > (SELECT MAX(run_identifier) - 4 FROM ctl.load_run)
ORDER BY run_identifier;
GO


/* ---- against RK's 60,863 ---- */

SELECT  rows_published = COUNT(*),
        members        = COUNT(DISTINCT member_identifier),
        spans_per_member = CAST(COUNT(*) * 1.0 / NULLIF(COUNT(DISTINCT member_identifier),0) AS decimal(9,2)),
        earliest_start = MIN(member_benefit_plan_start_date),
        latest_end     = MAX(member_benefit_plan_end_date)
FROM    pub.member_benefit_plan_span
WHERE   reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';
GO

SELECT  spans_held = n, members = COUNT(*)
FROM   (SELECT member_identifier, n = COUNT(*)
        FROM   pub.member_benefit_plan_span
        WHERE  reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M'
        GROUP BY member_identifier) d
GROUP BY n
ORDER BY n;
GO
