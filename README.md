USE [ODM];

WITH x AS (
  SELECT s.benefit_plan_identifier bp,
         s.member_benefit_plan_start_date st,
         s.member_benefit_plan_end_date   en
  FROM   odm.enrollment_benefit_plan_span s
  JOIN   odm.enrollment_member m   ON m.member_identifier = s.member_identifier
  JOIN   odm.enrollment_provider p ON p.member_identifier = s.member_identifier
                                  AND p.provider_relationship = 'Hosp'
                                  AND p.supplier_network_identifier = 'AltProvider004'
  WHERE (s.member_benefit_plan_end_date IS NULL
         OR s.member_benefit_plan_end_date > s.member_benefit_plan_start_date)
    AND  ISNULL(m.hcp_number,'') <> '956'
)
SELECT
 end_in_window_no_wr   = SUM(CASE WHEN (en IS NULL OR en >= DATEADD(month,-15,'2026-09-24')) AND st <= '2026-09-24' AND bp NOT IN ('WR001','WR002') THEN 1 ELSE 0 END),
 end_in_window_with_wr = SUM(CASE WHEN (en IS NULL OR en >= DATEADD(month,-15,'2026-09-24')) AND st <= '2026-09-24' THEN 1 ELSE 0 END),
 start_in_window_no_wr = SUM(CASE WHEN st >= DATEADD(month,-15,'2026-09-24') AND st <= '2026-09-24' AND bp NOT IN ('WR001','WR002') THEN 1 ELSE 0 END),
 start_in_window_w_wr  = SUM(CASE WHEN st >= DATEADD(month,-15,'2026-09-24') AND st <= '2026-09-24' THEN 1 ELSE 0 END),
 overlap_window_no_wr  = SUM(CASE WHEN st <= '2026-09-24' AND (en IS NULL OR en > DATEADD(month,-15,'2026-09-24')) AND bp NOT IN ('WR001','WR002') THEN 1 ELSE 0 END),
 no_window_no_wr       = SUM(CASE WHEN bp NOT IN ('WR001','WR002') THEN 1 ELSE 0 END)
FROM x;
