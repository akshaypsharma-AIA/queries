USE [ODM];
SELECT  attribute_name,
        members    = COUNT(DISTINCT member_identifier),
        rows_total = COUNT(*),
        max_rows_per_member = MAX(n)
FROM   (SELECT member_identifier, attribute_name,
               n = COUNT(*) OVER (PARTITION BY member_identifier, attribute_name)
        FROM   odm.enrollment_member_attribute
        WHERE  attribute_name LIKE '%Duplicate%'
           OR  attribute_name LIKE '%Merge%') d
GROUP BY attribute_name
ORDER BY attribute_name;


