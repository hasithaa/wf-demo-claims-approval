-- One Postgres container serves the integration side; each service keeps its own
-- database, so the separation between services stays real even though the demo
-- spends only one container on it.
CREATE DATABASE claims_db OWNER app;
CREATE DATABASE bills_db OWNER app;
CREATE DATABASE notifications_db OWNER app;
