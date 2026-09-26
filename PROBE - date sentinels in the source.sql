/* What date values does the source actually hold, on the rows we load?
   Each block applies that table's own load filter, so this profiles reality, not the whole table.
   PART A names every value outside a plausible real range.
   PART B is the summary per column. */

USE [ODM];
GO

DECLARE @as_of date = CAST(GETDATE() AS date);
DECLARE @lo    date = '1900-01-01';
DECLARE @hi    date = '2100-01-01';

/* ================= PART A. the actual out of range values ================= */

;WITH d AS (

    SELECT src='MEMBER', col='MEMBER_BIRTH_DATE',       v=CAST(m.MEMBER_BIRTH_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER m WITH (NOLOCK)
    WHERE (m.VERSION_EFF_DATE <= @as_of OR m.VERSION_EFF_DATE IS NULL)
      AND (m.VERSION_EXP_DATE >  @as_of OR m.VERSION_EXP_DATE IS NULL)
      AND  ISNULL(m.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'MEMBER','MEMBER_DEATH_DATE', CAST(m.MEMBER_DEATH_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER m WITH (NOLOCK)
    WHERE (m.VERSION_EFF_DATE <= @as_of OR m.VERSION_EFF_DATE IS NULL)
      AND (m.VERSION_EXP_DATE >  @as_of OR m.VERSION_EXP_DATE IS NULL)
      AND  ISNULL(m.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'MEMBER','MEMBER_EFFECTIVE_DATE', CAST(m.MEMBER_EFFECTIVE_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER m WITH (NOLOCK)
    WHERE (m.VERSION_EFF_DATE <= @as_of OR m.VERSION_EFF_DATE IS NULL)
      AND (m.VERSION_EXP_DATE >  @as_of OR m.VERSION_EXP_DATE IS NULL)
      AND  ISNULL(m.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'MEMBER','MEMBER_TERMINATION_DATE', CAST(m.MEMBER_TERMINATION_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER m WITH (NOLOCK)
    WHERE (m.VERSION_EFF_DATE <= @as_of OR m.VERSION_EFF_DATE IS NULL)
      AND (m.VERSION_EXP_DATE >  @as_of OR m.VERSION_EXP_DATE IS NULL)
      AND  ISNULL(m.DELETED_FLAG,'') <> 'Y'

UNION ALL
    SELECT 'MEMBER_PLAN_SELECTION','MEMBER_PLAN_START_DATE', CAST(p.MEMBER_PLAN_START_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_PLAN_SELECTION p WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(p.MEMBER_HCC_ID))
    WHERE  ISNULL(p.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'MEMBER_PLAN_SELECTION','MEMBER_PLAN_END_DATE', CAST(p.MEMBER_PLAN_END_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_PLAN_SELECTION p WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(p.MEMBER_HCC_ID))
    WHERE  ISNULL(p.DELETED_FLAG,'') <> 'Y'

UNION ALL
    SELECT 'ADDRESS (member)','EFF_DATE', CAST(a.EFF_DATE AS date)
    FROM   ODS_FINAL.dbo.ADDRESS a WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = a.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(a.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'ADDRESS (member)','END_DATE', CAST(a.END_DATE AS date)
    FROM   ODS_FINAL.dbo.ADDRESS a WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = a.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(a.DELETED_FLAG,'') <> 'Y'

UNION ALL
    SELECT 'MEMBER_OTHER_ID','EFFECTIVE_START_DATE', CAST(o.EFFECTIVE_START_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_OTHER_ID o WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = o.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(o.DELETED_FLAG,'') <> 'Y' AND o.ID_TYPE_CODE LIKE 'IT%'
UNION ALL
    SELECT 'MEMBER_OTHER_ID','EFFECTIVE_END_DATE', CAST(o.EFFECTIVE_END_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_OTHER_ID o WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = o.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(o.DELETED_FLAG,'') <> 'Y' AND o.ID_TYPE_CODE LIKE 'IT%'

UNION ALL
    SELECT 'MEMBER_PROVIDER','MEMBER_PROVIDER_EFFECTIVE_DATE', CAST(p.MEMBER_PROVIDER_EFFECTIVE_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_PROVIDER p WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = p.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(p.DELETED_FLAG,'') <> 'Y' AND p.MEMBER_PROVIDER_CURRENT_FLAG = 'Y'
UNION ALL
    SELECT 'MEMBER_PROVIDER','MEMBER_PROVIDER_EXPIRATION_DATE', CAST(p.MEMBER_PROVIDER_EXPIRATION_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_PROVIDER p WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = p.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(p.DELETED_FLAG,'') <> 'Y' AND p.MEMBER_PROVIDER_CURRENT_FLAG = 'Y'

UNION ALL
    SELECT 'COMPLIANCE_PROGRAM','MEMBER_COMPL_PROG_EFF_DATE', CAST(g.MEMBER_COMPL_PROG_EFF_DATE AS date)
    FROM   ODS_FINAL.dbo.COMPLIANCE_PROGRAM g WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = g.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(g.DELETED_FLAG,'') <> 'Y' AND g.MEMBER_COMPL_PROG_CURRENT_FLAG = 'Y'
UNION ALL
    SELECT 'COMPLIANCE_PROGRAM','MEMBER_COMPL_PROG_TERM_DATE', CAST(g.MEMBER_COMPL_PROG_TERM_DATE AS date)
    FROM   ODS_FINAL.dbo.COMPLIANCE_PROGRAM g WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.source_member_version_key = g.MEMBER_HISTORY_FACT_KEY
    WHERE  ISNULL(g.DELETED_FLAG,'') <> 'Y' AND g.MEMBER_COMPL_PROG_CURRENT_FLAG = 'Y'

UNION ALL
    SELECT 'MEMBER_OTHER_INSURANCE','EFFECTIVE_DATE', CAST(i.EFFECTIVE_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_OTHER_INSURANCE i WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(i.MEMBER_HCC_ID))
    WHERE  ISNULL(i.DELETED_FLAG,'') <> 'Y'
      AND (i.VERSION_EFF_DATE <= @as_of OR i.VERSION_EFF_DATE IS NULL)
      AND (i.VERSION_EXP_DATE >  @as_of OR i.VERSION_EXP_DATE IS NULL)
UNION ALL
    SELECT 'MEMBER_OTHER_INSURANCE','TERMINATION_DATE', CAST(i.TERMINATION_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_OTHER_INSURANCE i WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(i.MEMBER_HCC_ID))
    WHERE  ISNULL(i.DELETED_FLAG,'') <> 'Y'
      AND (i.VERSION_EFF_DATE <= @as_of OR i.VERSION_EFF_DATE IS NULL)
      AND (i.VERSION_EXP_DATE >  @as_of OR i.VERSION_EXP_DATE IS NULL)
)
SELECT   source_table = src
        ,column_name  = col
        ,sentinel_value = v
        ,rows = COUNT_BIG(*)
FROM     d
WHERE    v IS NOT NULL
  AND    v NOT BETWEEN @lo AND @hi
GROUP BY src, col, v
ORDER BY src, col, rows DESC;
GO


/* ================= PART B. summary per column =================
   Run this second. Shows how much of each column is real, NULL, or a sentinel. */

DECLARE @as_of2 date = CAST(GETDATE() AS date);
DECLARE @lo2 date = '1900-01-01', @hi2 date = '2100-01-01';

;WITH d AS (
    SELECT src='MEMBER_PLAN_SELECTION', col='MEMBER_PLAN_END_DATE', v=CAST(p.MEMBER_PLAN_END_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER_PLAN_SELECTION p WITH (NOLOCK)
    JOIN   odm.enrollment_member m ON m.member_identifier = LTRIM(RTRIM(p.MEMBER_HCC_ID))
    WHERE  ISNULL(p.DELETED_FLAG,'') <> 'Y'
UNION ALL
    SELECT 'MEMBER','MEMBER_TERMINATION_DATE', CAST(m2.MEMBER_TERMINATION_DATE AS date)
    FROM   ODS_FINAL.dbo.MEMBER m2 WITH (NOLOCK)
    WHERE (m2.VERSION_EFF_DATE <= @as_of2 OR m2.VERSION_EFF_DATE IS NULL)
      AND (m2.VERSION_EXP_DATE >  @as_of2 OR m2.VERSION_EXP_DATE IS NULL)
      AND  ISNULL(m2.DELETED_FLAG,'') <> 'Y'
)
SELECT   source_table = src
        ,column_name  = col
        ,total_rows   = COUNT_BIG(*)
        ,null_rows    = SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END)
        ,real_rows    = SUM(CASE WHEN v BETWEEN @lo2 AND @hi2 THEN 1 ELSE 0 END)
        ,sentinel_rows= SUM(CASE WHEN v IS NOT NULL AND v NOT BETWEEN @lo2 AND @hi2 THEN 1 ELSE 0 END)
        ,earliest_real= MIN(CASE WHEN v BETWEEN @lo2 AND @hi2 THEN v END)
        ,latest_real  = MAX(CASE WHEN v BETWEEN @lo2 AND @hi2 THEN v END)
FROM     d
GROUP BY src, col
ORDER BY src, col;
GO
