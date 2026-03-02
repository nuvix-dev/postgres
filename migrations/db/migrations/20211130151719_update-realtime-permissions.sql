-- migrate:up

-- Update future objects' permissions
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON TABLES TO postgres, nuvix_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON SEQUENCES TO postgres, nuvix_app;
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON ROUTINES TO postgres, nuvix_app;

-- migrate:down
