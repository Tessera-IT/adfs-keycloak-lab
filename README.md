# ADFS to Keycloak Migration Lab

A reproducible lab for testing SAML migrations from Active Directory Federation Services to Keycloak, plus write-ups of what actually broke along the way.

The setup runs both identity providers at once against the same directory, with two copies of the same application pointed at them. Comparing the two assertions side by side surfaces differences that a "can people still log in" test never will.

## Write-ups

**[What Actually Breaks When You Move a SAML App Off ADFS](writeups/01-saml-lab-failures.md)**
Standing up Keycloak with a working SAML flow, four distinct failures along the way, and why attribute names and NameID formats are where migrations actually go wrong.

**[Migrating a SAML Application from ADFS to Keycloak: A Claim-by-Claim Comparison](writeups/02-adfs-to-keycloak-comparison.md)**
The full comparison. Nested group resolution, Keycloak's default role claims, the primary group that cannot be synced over LDAP, and what each difference means in production.

## What's here

```
lab/
  docker-compose.yml     Keycloak, Postgres, and two SAML service providers
  Build-LabDomain.ps1    Builds a realistic AD structure: OUs, nested groups, 50 users
writeups/
  01-saml-lab-failures.md
  02-adfs-to-keycloak-comparison.md
```

## Running it

### Prerequisites

- Docker and Docker Compose
- A Windows Server VM with AD DS and ADFS, reachable from the Docker host
- Entries in your hosts file for `keycloak`, `sp.lab`, and `adfs.corp.lab`

### Certificates

The service providers need TLS because ADFS refuses plain HTTP assertion consumer endpoints.

```bash
mkdir -p lab/certs && cd lab/certs

openssl req -x509 -newkey rsa:2048 -nodes -days 1825 \
  -keyout sp.key -out sp.crt \
  -subj "/CN=sp.lab" \
  -addext "subjectAltName=DNS:sp.lab"

chmod 644 sp.key
```

The ADFS-facing SP also needs to trust the ADFS TLS certificate. Pull it straight off the wire rather than exporting it from the server:

```bash
echo | openssl s_client -connect adfs.corp.lab:443 -servername adfs.corp.lab 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > adfs-tls.pem
```

### Bring it up

```bash
cd lab
docker compose up -d
```

Keycloak admin console is at `http://keycloak:8080` with `admin` / `admin`. Create a realm named `lab` and a SAML client with client ID `saml-test-sp`.

### Build the directory

Run `Build-LabDomain.ps1` on the domain controller as a domain admin. It creates:

- A tiered OU structure with users separated by department
- Departmental, application, and role groups
- Deliberate group nesting, including a diamond that Keycloak's tree model cannot represent
- 50 users with department, title, manager, email, and UPN populated
- A read-only service account for Keycloak's LDAP bind

The nesting is the point. A flat directory will not reproduce the failures that matter.

## Notes

The compose file assumes the domain controller is at `192.168.56.10` on a VirtualBox host-only network. Adjust `extra_hosts` if yours differs.

The AD build script prompts for an account password at runtime rather than storing one. The compose file uses an obvious placeholder for the Postgres credential. Change both if you run this anywhere that matters, though nothing here is intended to be exposed.

Everything here uses throwaway credentials and self-signed certificates. It is a lab.

---

Built and maintained by [Tessera IT](mailto:adam@tesserait.com), an identity infrastructure consultancy in southern New Hampshire.
