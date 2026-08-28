-- Thunder SSO: group mappings and the permissions the mapped roles carry.
--
-- On every SSO login the ICP reads the ID token's `groups` claim (Thunder emits group
-- NAMES) and, for each sso_group_mappings row whose issuer+claim match, places the user
-- in the mapped ICP group. Roles flow from group_role_mapping, and human tasks are
-- gated on the ROLE NAMES — so Thunder's `managers` ends at role MANAGER, which is what
-- awaitHumanTask("reviewClaim", "MANAGER") checks.
--
-- Deterministic UUIDs so this script stays idempotent and readable.

-- The ICP groups the IdP groups land in. (Roles MANAGER/ACCOUNTANT come from
-- 30-demo-roles.sql.)
INSERT INTO user_groups (group_id, group_name, org_uuid, description)
SELECT v.gid, v.gname, 1, v.gdesc
  FROM (VALUES
        ('a1000000-0000-4000-8000-000000000001', 'Claim Managers',    'Thunder group: managers'),
        ('a1000000-0000-4000-8000-000000000002', 'Claim Accountants', 'Thunder group: accountants')
       ) AS v(gid, gname, gdesc)
 WHERE NOT EXISTS (SELECT 1 FROM user_groups g WHERE g.group_name = v.gname);

INSERT INTO group_role_mapping (group_id, role_id, org_uuid)
SELECT g.group_id, r.role_id, 1
  FROM user_groups g
  JOIN roles_v2 r
    ON (g.group_name = 'Claim Managers'    AND r.role_name = 'MANAGER')
    OR (g.group_name = 'Claim Accountants' AND r.role_name = 'ACCOUNTANT')
 WHERE NOT EXISTS (SELECT 1 FROM group_role_mapping m
                    WHERE m.group_id = g.group_id AND m.role_id = r.role_id);

-- The IdP-claim → ICP-group mappings. Issuer must string-equal the ID token's `iss`,
-- which is Thunder's public_url. Fresh installs interpolate it below via psql -v; the
-- default matches the compose defaults.
INSERT INTO sso_group_mappings (mapping_id, org_uuid, issuer, claim_name, claim_value, group_id)
SELECT v.mid, 1, 'https://localhost:8090', 'groups', v.cval, g.group_id
  FROM (VALUES
        ('a2000000-0000-4000-8000-000000000001', 'managers',    'Claim Managers'),
        ('a2000000-0000-4000-8000-000000000002', 'accountants', 'Claim Accountants')
       ) AS v(mid, cval, gname)
  JOIN user_groups g ON g.group_name = v.gname
 WHERE NOT EXISTS (SELECT 1 FROM sso_group_mappings m WHERE m.mapping_id = v.mid);

-- Mapped roles need real permissions: the console gates its navigation (and, in
-- federated mode, the login itself) on permissions, not role names. Managers see and
-- decide human tasks and watch executions; accountants see and decide human tasks.
INSERT INTO role_permission_mapping (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM roles_v2 r
  JOIN permissions p ON p.permission_name = ANY (
        CASE r.role_name
            WHEN 'MANAGER' THEN ARRAY['workflow_mgt:view_human_tasks', 'workflow_mgt:manage_human_tasks',
                                      'workflow_mgt:view_workflows',
                                      'project_mgt:view', 'integration_mgt:view']
            WHEN 'ACCOUNTANT' THEN ARRAY['workflow_mgt:view_human_tasks', 'workflow_mgt:manage_human_tasks',
                                         'workflow_mgt:view_workflows',
                                         'project_mgt:view', 'integration_mgt:view']
        END)
 WHERE r.role_name IN ('MANAGER', 'ACCOUNTANT')
   AND NOT EXISTS (SELECT 1 FROM role_permission_mapping m
                    WHERE m.role_id = r.role_id AND m.permission_id = p.permission_id);
