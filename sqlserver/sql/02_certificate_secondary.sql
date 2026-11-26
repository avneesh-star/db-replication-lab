-- Run on sql2 and sql3: import the certificate sql1 exported.
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
    CREATE CERTIFICATE ag_cert
        AUTHORIZATION dbm_user
        FROM FILE = '/certs/ag_cert.cer'
        WITH PRIVATE KEY (FILE = '/certs/ag_cert.pvk', DECRYPTION BY PASSWORD = 'PrivateKey_Passw0rd!');
GO
