USE [ODM];

-- A. does the HOSP join multiply?
SELECT  hosp_rows_per_member = n, members = COUNT(*)
FROM   (SELECT member_identifier, n = COUNT(*)
        FROM   odm.enrollment_provider
        WHERE  provider_relationship = 'Hosp'
        GROUP BY member_identifier) d
GROUP BY n ORDER BY n;

-- B. does the PCP join multiply?
SELECT  pcp_rows_per_member = n, members = COUNT(*)
FROM   (SELECT member_identifier, n = COUNT(*)
        FROM   odm.enrollment_provider
        WHERE  provider_relationship = 'PCP'
        GROUP BY member_identifier) d
GROUP BY n ORDER BY n;

-- C. the member in the error
SELECT  s.benefit_plan_identifier, s.member_benefit_plan_start_date, s.member_benefit_plan_end_date
FROM    odm.enrollment_benefit_plan_span s
WHERE   s.member_identifier = '00000856000'
ORDER BY s.member_benefit_plan_start_date;

SELECT  provider_relationship, supplier_network_identifier, effective_date, expiration_date
FROM    odm.enrollment_provider
WHERE   member_identifier = '00000856000'
ORDER BY provider_relationship, effective_date;
