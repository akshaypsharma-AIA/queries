USE [ODM];

WITH scoped AS (
  SELECT s.member_identifier, s.benefit_plan_identifier,
         s.member_benefit_plan_start_date st, s.member_benefit_plan_end_date en,
         m.hcp_number,
         nb = UPPER(ISNULL(nb.attribute_value,'FALSE')),
         dup= UPPER(ISNULL(dp.attribute_value,'FALSE')),
         has_cin_ext = CASE WHEN EXISTS (SELECT 1 FROM odm.enrollment_identifier ce
                                         WHERE ce.member_identifier = s.member_identifier
                                           AND ce.id_type_code='IT011'
                                           AND NULLIF(LTRIM(RTRIM(ce.identification_number)),'') IS NOT NULL)
                            THEN 1 ELSE 0 END
  FROM   odm.enrollment_benefit_plan_span s
  JOIN   odm.enrollment_member m   ON m.member_identifier = s.member_identifier
  JOIN   odm.enrollment_provider p ON p.member_identifier = s.member_identifier
                                  AND p.provider_relationship = 'Hosp'
                                  AND p.supplier_network_identifier = 'AltProvider004'
  LEFT JOIN odm.enrollment_member_attribute nb
         ON nb.member_identifier = s.member_identifier AND nb.attribute_name='Newborn'
  LEFT JOIN odm.enrollment_member_attribute dp
         ON dp.member_identifier = s.member_identifier AND dp.attribute_name='Duplicate Invalid Record'
)
SELECT
  base_all_rules        = SUM(CASE WHEN ok=1 THEN 1 ELSE 0 END),
  add_zero_day_spans    = SUM(CASE WHEN ok=0 AND zero_day=1 THEN 1 ELSE 0 END),
  add_wr_plans          = SUM(CASE WHEN ok=0 AND zero_day=0 AND wr=1 THEN 1 ELSE 0 END),
  add_future_start      = SUM(CASE WHEN ok=0 AND zero_day=0 AND wr=0 AND future=1 THEN 1 ELSE 0 END),
  add_no_cin_ext        = SUM(CASE WHEN ok=0 AND zero_day=0 AND wr=0 AND future=0 AND has_cin_ext=0 THEN 1 ELSE 0 END),
  add_newborn_or_dup    = SUM(CASE WHEN ok=0 AND zero_day=0 AND wr=0 AND future=0 AND has_cin_ext=1
                                        AND (nb='TRUE' OR dup='TRUE') THEN 1 ELSE 0 END),
  add_outside_window    = SUM(CASE WHEN ok=0 AND zero_day=0 AND wr=0 AND future=0 AND has_cin_ext=1
                                        AND nb<>'TRUE' AND dup<>'TRUE' AND hcp_number<>'956' THEN 1 ELSE 0 END),
  grand_total_all_spans = COUNT(*)
FROM (
  SELECT *,
    zero_day = CASE WHEN en IS NOT NULL AND en <= st THEN 1 ELSE 0 END,
    wr       = CASE WHEN benefit_plan_identifier IN ('WR001','WR002') THEN 1 ELSE 0 END,
    future   = CASE WHEN st > '2026-09-01' THEN 1 ELSE 0 END,
    ok = CASE WHEN (en IS NULL OR en > st)
               AND st <= '2026-09-01'
               AND (en IS NULL OR en >= DATEADD(month,-15,'2026-09-01'))
               AND benefit_plan_identifier NOT IN ('WR001','WR002')
               AND ISNULL(hcp_number,'') <> '956'
               AND nb <> 'TRUE' AND dup <> 'TRUE'
               AND has_cin_ext = 1
              THEN 1 ELSE 0 END
  FROM scoped) d;
