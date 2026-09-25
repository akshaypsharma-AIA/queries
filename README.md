USE [ODM];
SELECT name, definition = OBJECT_DEFINITION(object_id)
FROM   sys.check_constraints
WHERE  parent_object_id = OBJECT_ID('cfg.publication_feed');
