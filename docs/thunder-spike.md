# Thunder 1.0.0 spike — what phase 3 builds on

Findings from running `ghcr.io/thunder-id/thunderid:1.0.0` and reading `thunder-id/thunder`
at tag v1.0.0. Everything the SSO and portal phases assume, verified.

## Lifecycle (already wired into compose)

- First boot must run `./setup.sh`: it generates the key material (`config/certs/`), the
  `direct_auth_secret`, and the admin user, then bootstraps default resources. Plain
  `./start.sh` fails without it. Compose runs `setup.sh` once (guarded on
  `config/certs/crypto.key`), then serves; `config/` is a persisted volume — losing it
  invalidates every issued token.
- Admin credentials come from `ADMIN_USERNAME` / `ADMIN_PASSWORD` env.
- OIDC discovery: `GET /.well-known/openid-configuration` — issuer, `/oauth2/authorize`,
  `/oauth2/token`, `/oauth2/jwks`, `/oauth2/userinfo`. TLS on 8090, self-signed.

## Seeding users, groups, and apps — declarative, not scripted

`./start.sh <resources.yaml>` loads a multi-document YAML (documents tagged
`resource_type: user|group|application|role|resource_server|…`, `${VAR}` substitution,
handles like `ouHandle: default` resolve to ids). Users, groups, and OAuth applications
can all be seeded this way, so phase 3 ships one `thunder-resources.yaml` with
Jane/John/Alice/Bob, the `managers`/`accountants`/`users` groups, and the portal + ICP
apps — no API scripting. Caveats: declarative resources are read-only at runtime, and
`./start.sh file.yaml` REPLACES the default resource lookup rather than merging.
The same YAML also applies at runtime via `POST /import` with a `system`-scope token.

## Management APIs (`/users`, `/groups`, `/applications`)

Bearer JWT issued by Thunder itself, with the `system` scope (one seeded permission,
hierarchical — it satisfies `system:user`, `system:group:view`, …). For scripts: a
confidential app with `grantTypes: [client_credentials]`, granted the permission by
adding the app to the Administrators group, then

```
POST /oauth2/token
  grant_type=client_credentials&scope=system&resource=https://localhost:8090/mcp
```

The `resource` indicator (RFC 8707) is required — permission scopes are minted against
the seeded System resource server (identifier `…/mcp`); omitting it is `invalid_target`.

`Direct-Auth-Secret` is NOT for these APIs: it gates only the Direct APIs
(`/auth/credentials/authenticate` and friends, plus `/access/**`) — the endpoints a
trusted backend uses to authenticate users directly. That is what the portal's task API
could use if it ever needs password verification server-side.

## The groups claim (the SSO linchpin)

- Claim name **`groups`**, value: array of group **names** (transitive), omitted when empty.
- Opt-in, two gates on the application:
  1. `token.accessToken.userConfig.attributes` (and/or `token.idToken.userAttributes`)
     must list `groups`;
  2. for the ID token, a scope in the app's `scopeClaims` must map to it — the seeded
     console maps scope `group` → `["groups"]`; our apps define their own.
- So the ICP SSO group mapping consumes `groups: ["managers"]` etc. by group NAME — the
  phase-3 mapping rows are name → ICP role (`managers` → `MANAGER`).

## OIDC details that matter for our RPs

- `response_types_supported: ["code"]` only; PKCE **S256 only** (`plain` rejected);
  public clients force PKCE, confidential default to off.
- Token endpoint auth: `client_secret_basic` (credentials passed verbatim, not
  URL-decoded), `client_secret_post`, `private_key_jwt`, `none`.
- `aud` is a single string; one `resource` per request.
- client_credentials tokens carry `sub` = client_id, no refresh token, no ID token.
