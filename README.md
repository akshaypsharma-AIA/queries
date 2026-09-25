USE [ODM];
SELECT  p.provider_relationship,
        p.supplier_network_identifier,
        members = COUNT(DISTINCT p.member_identifier)
FROM    odm.enrollment_provider p
WHERE   p.supplier_network_identifier IS NOT NULL
GROUP BY p.provider_relationship, p.supplier_network_identifier
HAVING  COUNT(DISTINCT p.member_identifier) >= 1000
ORDER BY members DESC;
