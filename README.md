USE [ODM];

SELECT  s.benefit_plan_identifier,
        spans   = COUNT(*),
        members = COUNT(DISTINCT s.member_identifier),
        open_spans = SUM(CASE WHEN s.member_benefit_plan_end_date IS NULL THEN 1 ELSE 0 END),
        closed_spans = SUM(CASE WHEN s.member_benefit_plan_end_date IS NOT NULL THEN 1 ELSE 0 END)
FROM    odm.enrollment_benefit_plan_span s
JOIN    odm.enrollment_provider p ON p.member_identifier = s.member_identifier
                                 AND p.provider_relationship = 'Hosp'
                                 AND p.supplier_network_identifier = 'AltProvider004'
WHERE   s.member_benefit_plan_start_date <= '2026-09-01'
  AND  (s.member_benefit_plan_end_date IS NULL
        OR s.member_benefit_plan_end_date >= DATEADD(month,-15,'2026-09-01'))
  AND  (s.member_benefit_plan_end_date IS NULL
        OR s.member_benefit_plan_end_date > s.member_benefit_plan_start_date)
GROUP BY s.benefit_plan_identifier
ORDER BY spans DESC;
