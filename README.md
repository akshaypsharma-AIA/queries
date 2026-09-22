# queries



/* 834 outbound -- developer walkthrough. Six queries, in order.
   Run one at a time. Each one makes a single point.
   A Sharma, 22 Sep 2026. */

USE [ODM];
GO
SET NOCOUNT ON;
GO

/* ==================================================================================
   1. THE FOUR LAYERS
   "Data moves in one direction. Each layer has one job."
   ================================================================================== */

SELECT layer = '1 ODS_FINAL  source, every version of every member',
       rows_found = (SELECT COUNT_BIG(*) FROM ODS_FINAL.dbo.MEMBER WITH (NOLOCK))
UNION ALL
SELECT '2 odm        current state, one row per member',
       (SELECT COUNT_BIG(*) FROM odm.enrollment_member)
UNION ALL
SELECT '3 odm        one row per member per plan per span',
       (SELECT COUNT_BIG(*) FROM odm.enrollment_benefit_plan_span)
UNION ALL
SELECT '4 pub        what goes in the file. one row = one INS + one HD loop',
       (SELECT COUNT_BIG(*) FROM pub.member_benefit_plan_span);
GO
/* 12.2 million versions become 1.49 million members become 2.02 million published rows. */


/* ==================================================================================
   2. ONE MEMBER, END TO END
   "This is what a developer will actually query."
   ================================================================================== */

DECLARE @m varchar(50) = (SELECT TOP 1 member_identifier
                          FROM   pub.member_benefit_plan_span
                          WHERE  reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M'
                          ORDER BY member_identifier);

SELECT what = 'the published row', benefit_plan_identifier,
       member_benefit_plan_start_date, member_benefit_plan_end_date,
       city_name, state_code, county_code, hcp_number,
       full_scope_flag, share_of_cost_flag, ccs_flag, direct_member_flag, wellrec_scope
FROM   pub.member_benefit_plan_span
WHERE  member_identifier = @m AND reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';

SELECT what = 'their languages', language_use_indicator, language_code
FROM   pub.member_language
WHERE  member_identifier = @m AND reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M';

SELECT what = 'their other insurance', carrier_sequence, carrier_name,
       coverage_scope_code, cob_effective_date, cob_termination_date
FROM   pub.member_other_insurance
WHERE  member_identifier = @m AND reference_date = '2026-09-01' AND feed_code = 'NORTHBAY_M'
ORDER BY carrier_sequence;
GO


/* ==================================================================================
   3. THE DEFINITIONS LIVE ON THE TABLE
   "You do not need a document. Right click the column."
   ================================================================================== */

SELECT  column_name = c.name,
        definition  = CAST(ep.value AS nvarchar(max))
FROM    sys.columns c
JOIN    sys.extended_properties ep
     ON  ep.major_id = c.object_id AND ep.minor_id = c.column_id
     AND ep.name = 'MS_Description'
WHERE   c.object_id = OBJECT_ID('pub.member_benefit_plan_span')
  AND   c.name IN ('member_benefit_plan_end_date','cin_identifier','aid_code',
                   'direct_member_flag','wellrec_scope')
ORDER BY c.column_id;
GO
/* loop, segment, element, qualifier, the rule, the source column, an example. All 56 have it. */


/* ==================================================================================
   4. THE GRAIN, PROVEN NOT ASSERTED
   "One row per member per plan per span. Here is the proof."
   ================================================================================== */

SELECT  probe        = 'pub.member_benefit_plan_span',
        rows_found   = COUNT_BIG(*),
        distinct_key = COUNT(DISTINCT CONCAT(reference_date,'|',feed_code,'|',member_identifier,'|',
                                             benefit_plan_identifier,'|',member_benefit_plan_start_date))
FROM    pub.member_benefit_plan_span;

SELECT  spans_per_member = c, members = COUNT_BIG(*)
FROM   (SELECT member_identifier, c = COUNT_BIG(*)
        FROM   pub.member_benefit_plan_span
        GROUP BY member_identifier) x
GROUP BY c ORDER BY 1;
GO


/* ==================================================================================
   5. THE CONFIG TABLE DRIVES EVERY PARTNER
   "No code changes per trading partner. One row each."
   ================================================================================== */

SELECT  feed_code, partner_code, file_type, agreed_file_frequency, active_flag,
        span_policy, eligibility_date_source, member_status_filter,
        capitation_network_scope, exclude_newborn_flag, exclude_wellrec_only_flag
FROM    cfg.publication_feed
ORDER BY active_flag DESC, feed_code;
GO
/* 25 feeds, 13 partners, one code base. */


/* ==================================================================================
   6. HOW YOU KNOW A LOAD WORKED
   "Every entity times itself and compares to last time."
   ================================================================================== */

SELECT TOP 15 entity_name, rows_loaded_count, rows_previous_run_count, pct_change,
       status_code, seconds = DATEDIFF(second, started_at, finished_at), halt_reason
FROM   ctl.load_run
ORDER BY run_identifier DESC;
GO
/* read it bottom up. that is execution order. */
