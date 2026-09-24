UPDATE cfg.publication_feed SET eligibility_date_source = 'Hosp' WHERE feed_code = 'NORTHBAY_M';


USE [ODM];

SELECT  rows_span  = COUNT(*),
        members    = COUNT(DISTINCT s.member_identifier),
        per_member = CAST(COUNT(*)*1.0/NULLIF(COUNT(DISTINCT s.member_identifier),0) AS decimal(9,2))
FROM    odm.enrollment_benefit_plan_span s
JOIN    odm.enrollment_member m   ON m.member_identifier = s.member_identifier
JOIN    odm.enrollment_provider p ON p.member_identifier = s.member_identifier
                                 AND p.provider_relationship = 'Hosp'
                                 AND p.supplier_network_identifier = 'AltProvider004'
LEFT JOIN odm.enrollment_member_attribute nb
       ON nb.member_identifier = s.member_identifier AND nb.attribute_name = 'Newborn'
LEFT JOIN odm.enrollment_member_attribute dup
       ON dup.member_identifier = s.member_identifier AND dup.attribute_name = 'Duplicate Invalid Record'
WHERE  (s.member_benefit_plan_end_date IS NULL
        OR s.member_benefit_plan_end_date > s.member_benefit_plan_start_date)
  AND   s.member_benefit_plan_start_date <= '2026-09-01'
  AND  (s.member_benefit_plan_end_date IS NULL
        OR s.member_benefit_plan_end_date >= DATEADD(month,-15,'2026-09-01'))
  AND   s.benefit_plan_identifier NOT IN ('WR001','WR002')
  AND   ISNULL(m.hcp_number,'') <> '956'
  AND   UPPER(ISNULL(nb.attribute_value,'FALSE'))  <> 'TRUE'
  AND   UPPER(ISNULL(dup.attribute_value,'FALSE')) <> 'TRUE'
  AND   EXISTS (SELECT 1 FROM odm.enrollment_identifier ce
                WHERE ce.member_identifier = s.member_identifier
                  AND ce.id_type_code = 'IT011'
                  AND NULLIF(LTRIM(RTRIM(ce.identification_number)),'') IS NOT NULL);
