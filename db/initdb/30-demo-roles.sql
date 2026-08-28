-- Demo task roles, until Thunder SSO group mappings replace them (phase 3).
--
-- Human tasks are role-gated by NAME: `awaitHumanTask("reviewClaim", "MANAGER")` is
-- visible only to a caller whose token carries a role named MANAGER. The seeded admin
-- holds "Super Admin"/"Project Admin", so without this the task views are correctly
-- empty — which looks like a bug and is not one. Granting both demo roles to the
-- Super Admins group lets the admin play every part while the portals are being built.
INSERT INTO roles_v2 (role_id, role_name, org_id, description)
SELECT gen_random_uuid()::text, r.name, 1, 'Claimflow demo task role'
  FROM (VALUES ('MANAGER'), ('ACCOUNTANT')) AS r(name)
 WHERE NOT EXISTS (SELECT 1 FROM roles_v2 WHERE role_name = r.name);

INSERT INTO group_role_mapping (group_id, role_id, org_uuid)
SELECT g.group_id, r.role_id, 1
  FROM user_groups g
  JOIN roles_v2 r ON r.role_name IN ('MANAGER', 'ACCOUNTANT')
 WHERE g.group_name = 'Super Admins'
   AND NOT EXISTS (
        SELECT 1 FROM group_role_mapping m
         WHERE m.group_id = g.group_id AND m.role_id = r.role_id);
