-- migrate:up

-- Update future objects' permissions
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON TABLES TO postgres, nuvix;
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON SEQUENCES TO postgres, nuvix;
ALTER DEFAULT PRIVILEGES FOR ROLE nuvix_admin IN SCHEMA realtime GRANT ALL ON ROUTINES TO postgres, nuvix;

-- migrate:down
