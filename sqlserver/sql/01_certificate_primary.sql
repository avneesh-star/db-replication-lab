-- Run on sql1. Replicas authenticate to each other's endpoints with a certificate.
-- sql1 creates it and exports it with its private key to the shared volume;
-- the secondaries import the same certificate (02_certificate_secondary.sql).
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'MasterKey_Passw0rd!';
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'dbm_login')
    CREATE LOGIN dbm_login WITH PASSWORD = 'DbmLogin_Passw0rd!';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'dbm_user')
    CREATE USER dbm_user FOR LOGIN dbm_login;
GO
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'ag_cert')
BEGIN
    CREATE CERTIFICATE ag_cert
        WITH SUBJECT = 'Availability group endpoint', EXPIRY_DATE = '20351231';
    BACKUP CERTIFICATE ag_cert TO FILE = '/certs/ag_cert.cer'
        WITH PRIVATE KEY (FILE = '/certs/ag_cert.pvk', ENCRYPTION BY PASSWORD = 'PrivateKey_Passw0rd!');
END
GO
