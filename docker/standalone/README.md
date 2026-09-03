# Standalone - OpenLDAP mono-instance

Single-host deployment of OpenLDAP 2.6 + phpLDAPadmin + Self Service Password via Docker Compose.

## Usage

```bash
# Optional: generate TLS certs
bash certs.sh

# Bootstrap config + initial data + start containers
bash setup.sh

# Wipe and reinitialize
bash setup.sh --reset
```

## Services

| Service               | URL                    | Default login                                           |
| --------------------- | ---------------------- | ------------------------------------------------------- |
| OpenLDAP              | `ldap://localhost:389` | `cn=admin,ou=users,dc=example,dc=org` / `adminpassword` |
| phpLDAPadmin          | http://localhost:8080  | `admin` / `adminpassword`                               |
| Self Service Password | http://localhost:8088  | Any LDAP user                                           |

## Files

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | OpenLDAP + phpLDAPadmin + SSP |
| `setup.sh` | Bootstrap (`slapadd` cn=config + data, fix perms, `docker compose up`) |
| `init-config/slapd-config.ldif` | Full `cn=config` (modules, schemas, ACLs, overlays, accesslog) |
| `ssp.conf.php.example` | Self Service Password configuration template - `setup.sh` renders it to `ssp.conf.php` (gitignored) with a random `$keyphrase` |
| `data/` | Persistent OpenLDAP data (`slapd.d`, MDB, accesslog) - gitignored |

Shared with other modes (parent directory):

| Path | Purpose |
|------|---------|
| `../base-ldifs/` | Base directory data (users, groups, policies) |
| `certs.sh` + `certs/` | TLS cert generation/renewal (idempotent; see root README for cron) |
| `backup/` | Backup dump location |

For day-to-day administration (users, groups, ppolicy, diagnostics) use **[openldap-cli](https://github.com/maximewewer/openldap-cli)** - see root README → *Administration - openldap-cli*.

## Database sizing

Default `olcDbMaxSize: 1 GiB` per DB (main `dc=…`, `cn=accesslog`, `cn=config`). Under bind audit (`olcAccessLogOps: writes bind`), the `cn=accesslog` DB can saturate within weeks - once full (`MDB_MAP_FULL`), writes cascade-fail and **binds appear as "Invalid credentials"** (ppolicy can't update its counters). Tune the accesslog overlay or live-resize `olcDbMaxSize` (no restart). See [root README - Database storage & sizing](../README.md#database-storage--sizing).
