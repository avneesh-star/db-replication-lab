-- Run on sql2 and sql3: join the availability group sql1 created, and allow
-- automatic seeding to create the replicated database here.
USE master;
GO
ALTER AVAILABILITY GROUP lab_ag JOIN WITH (CLUSTER_TYPE = NONE);
GO
ALTER AVAILABILITY GROUP lab_ag GRANT CREATE ANY DATABASE;
GO
