# What Actually Breaks When You Move a SAML App Off ADFS

Most write-ups about migrating from Active Directory Federation Services to Keycloak stop at "stand up Keycloak, point the app at it, done." That framing is why migrations slip. Authentication is rarely the hard part. A SAML login flow will usually work on the first or second attempt. What breaks is everything *around* the login: the identifier the application uses to recognize a returning user, and the attributes it expects to find in the assertion.

Both of those silently change when you swap identity providers. Neither produces an error message that points at the real cause.

This is a walkthrough of a lab I built to isolate those failure modes, the four distinct ways it broke along the way, and why each one maps to something that shows up in production cutovers.

---

## The lab

Two containers and a service provider, all local. This is the compose file as it stood at this stage. The one in `lab/` is the final version, with TLS and a second SP for the ADFS comparison.

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: labpassword
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: labpassword
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
    ports:
      - "8080:8080"
    depends_on:
      - postgres
    restart: unless-stopped

  saml-sp:
    image: ghcr.io/beryju/saml-test-sp
    network_mode: host
    environment:
      SP_ENTITY_ID: saml-test-sp
      SP_ROOT_URL: http://localhost:9009
      SP_METADATA_URL: http://127.0.0.1:8080/realms/lab/protocol/saml/descriptor
    restart: unless-stopped

volumes:
  pgdata:
```

Postgres rather than the embedded database, because Keycloak's default H2 store is explicitly not for anything you intend to keep. A dedicated `lab` realm, one test user, one SAML client.

The service provider is a small Go application built on the `crewjam/saml` library. It does one useful thing: after a successful login it dumps the parsed assertion as JSON. Being able to see exactly what arrived, rather than inferring it from whether an app worked, is the entire point of a lab like this.

A note on Keycloak 26: the admin bootstrap environment variables were renamed to `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD`. A large amount of tutorial content still uses the older `KEYCLOAK_ADMIN` form, which now silently fails to create an admin user.

---

## Four ways it broke

### 1. Client signature required

Keycloak's default for a new SAML client is to require that the service provider sign its authentication requests. Many real applications don't sign, and the test SP doesn't either.

The symptom is a rejection at the very start of the flow, before any login page appears. Toggling **Client signature required** off on the client's Keys tab resolves it.

Worth flagging as a deliberate decision rather than a checkbox: in production you generally *want* signed requests. But if the relying party you're migrating never signed requests against ADFS, turning this on during cutover introduces a change the application wasn't asked about.

### 2. Issuer mismatch

This one produced a clean error, and it's the most instructive of the four:

```
response Issuer does not match the IDP metadata (expected "saml-test-sp")
```

The assertion itself was fine. Status Success, correct audience, correct destination, valid signature, role attributes present. The SP rejected it because it had been configured with the IdP's SSO URL and signing certificate manually, and had constructed a synthetic metadata record with the wrong entity ID.

The fix was to stop hand-feeding it and let it fetch Keycloak's real SAML descriptor:

```
http://<host>:8080/realms/<realm>/protocol/saml/descriptor
```

**Why this matters beyond the lab.** Issuer mismatch is one of the most common causes of a broken relying party after an ADFS cutover, for a structural reason: ADFS identifies itself with a URI like

```
http://adfs.company.com/adfs/services/trust
```

while Keycloak uses the realm URL:

```
https://idp.company.com/realms/production
```

Every application that pinned the old issuer, whether in configuration, in a database row, or in a hardcoded constant, stops accepting assertions at cutover. Applications that consume metadata dynamically handle it transparently. Applications with a hand-configured issuer string do not, and the error they surface to users is usually far less specific than the one above.

Inventorying which relying parties hardcode the issuer is a pre-migration task, not a cutover-day discovery.

### 3. Metadata fetched at startup, over IPv6

The SP entered a crash loop:

```
panic: Get "http://localhost:8080/realms/lab/protocol/saml/descriptor":
dial tcp [::1]:8080: connect: connection refused
```

Two things going on. First, `localhost` resolved to the IPv6 loopback, and the published Docker port wasn't listening there. Using `127.0.0.1` explicitly resolved it.

Second, and more interesting: the stack trace shows the metadata fetch happening inside `LoadConfig()` during startup, not lazily on first request as the documentation suggests. That makes the SP hard-dependent on the IdP being reachable at boot. A `depends_on` won't help, because container start order doesn't guarantee application readiness.

The general lesson transfers directly to production: anything that consumes IdP metadata at startup rather than on demand will fail to start during an identity provider outage, and will need a restart afterward even once the IdP recovers. That turns a five-minute IdP blip into a much longer application outage. It's worth knowing which of your relying parties behave this way *before* you plan a maintenance window.

The portable alternative to host networking, and closer to a real deployment: put both containers on the same Docker network, reference Keycloak by its service name, and add a matching hosts-file entry so the browser resolves the same name to the same server.

### 4. A 404 from typing the wrong URL

Included because it's honest, and because it accounts for a meaningful share of time lost in identity work. When something in a redirect chain fails, the first hypothesis should be that the URL is wrong, not that the protocol is broken.

---

## The part that actually matters: attributes

Here's the first successful assertion, straight out of the SP:

```json
{
  "aud": "http://localhost:9009",
  "iss": "http://localhost:9009",
  "sub": "G-377a8e1d-1aab-4540-8562-ab085a7fad68",
  "attr": {
    "Role": [
      "uma_authorization",
      "manage-account-links",
      "offline_access",
      "view-profile",
      "default-roles-lab",
      "manage-account"
    ],
    "SessionIndex": ["ea589ca5-0293-49c1-afb6-972bbdca7b24::..."]
  },
  "saml-session": true
}
```

Authentication succeeded. And the assertion contains essentially nothing an application could use.

No email. No username. No display name. Just Keycloak's own built-in roles, emitted under an attribute literally named `Role` with the basic name format.

This is the gap that breaks migrations. ADFS deployments accumulate claim rules over years, often written by someone who has since left, and applications quietly depend on them. Keycloak sends almost nothing until you configure it to, and the failure mode isn't a login error. It's a successful login followed by an application that can't find a user record, or renders a blank profile, or throws a null reference somewhere deep in a request handler.

### Naming is the second half of the problem# What Actually Breaks When You Move a SAML App Off ADFS

Most write-ups about migrating from Active Directory Federation Services to Keycloak stop at "stand up Keycloak, point the app at it, done." That framing is why migrations slip. Authentication is rarely the hard part. A SAML login flow will usually work on the first or second attempt. What breaks is everything *around* the login: the identifier the application uses to recognize a returning user, and the attributes it expects to find in the assertion.

Both of those silently change when you swap identity providers. Neither produces an error message that points at the real cause.

This is a walkthrough of a lab I built to isolate those failure modes, the four distinct ways it broke along the way, and why each one maps to something that shows up in production cutovers.

---

## The lab

Two containers and a service provider, all local:

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: labpassword
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: labpassword
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
    ports:
      - "8080:8080"
    depends_on:
      - postgres
    restart: unless-stopped

  saml-sp:
    image: ghcr.io/beryju/saml-test-sp
    network_mode: host
    environment:
      SP_ENTITY_ID: saml-test-sp
      SP_ROOT_URL: http://localhost:9009
      SP_METADATA_URL: http://127.0.0.1:8080/realms/lab/protocol/saml/descriptor
    restart: unless-stopped

volumes:
  pgdata:
```

Postgres rather than the embedded database, because Keycloak's default H2 store is explicitly not for anything you intend to keep. A dedicated `lab` realm, one test user, one SAML client.

The service provider is a small Go application built on the `crewjam/saml` library. It does one useful thing: after a successful login it dumps the parsed assertion as JSON. Being able to see exactly what arrived, rather than inferring it from whether an app worked, is the entire point of a lab like this.

A note on Keycloak 26: the admin bootstrap environment variables were renamed to `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD`. A large amount of tutorial content still uses the older `KEYCLOAK_ADMIN` form, which now silently fails to create an admin user.

---

## Four ways it broke

### 1. Client signature required

Keycloak's default for a new SAML client is to require that the service provider sign its authentication requests. Many real applications don't sign, and the test SP doesn't either.

The symptom is a rejection at the very start of the flow, before any login page appears. Toggling **Client signature required** off on the client's Keys tab resolves it.

Worth flagging as a deliberate decision rather than a checkbox: in production you generally *want* signed requests. But if the relying party you're migrating never signed requests against ADFS, turning this on during cutover introduces a change the application wasn't asked about.

### 2. Issuer mismatch

This one produced a clean error, and it's the most instructive of the four:

```
response Issuer does not match the IDP metadata (expected "saml-test-sp")
```

The assertion itself was fine. Status Success, correct audience, correct destination, valid signature, role attributes present. The SP rejected it because it had been configured with the IdP's SSO URL and signing certificate manually, and had constructed a synthetic metadata record with the wrong entity ID.

The fix was to stop hand-feeding it and let it fetch Keycloak's real SAML descriptor:

```
http://<host>:8080/realms/<realm>/protocol/saml/descriptor
```

**Why this matters beyond the lab.** Issuer mismatch is one of the most common causes of a broken relying party after an ADFS cutover, for a structural reason: ADFS identifies itself with a URI like

```
http://adfs.company.com/adfs/services/trust
```

while Keycloak uses the realm URL:

```
https://idp.company.com/realms/production
```

Every application that pinned the old issuer, whether in configuration, in a database row, or in a hardcoded constant, stops accepting assertions at cutover. Applications that consume metadata dynamically handle it transparently. Applications with a hand-configured issuer string do not, and the error they surface to users is usually far less specific than the one above.

Inventorying which relying parties hardcode the issuer is a pre-migration task, not a cutover-day discovery.

### 3. Metadata fetched at startup, over IPv6

The SP entered a crash loop:

```
panic: Get "http://localhost:8080/realms/lab/protocol/saml/descriptor":
dial tcp [::1]:8080: connect: connection refused
```

Two things going on. First, `localhost` resolved to the IPv6 loopback, and the published Docker port wasn't listening there. Using `127.0.0.1` explicitly resolved it.

Second, and more interesting: the stack trace shows the metadata fetch happening inside `LoadConfig()` during startup, not lazily on first request as the documentation suggests. That makes the SP hard-dependent on the IdP being reachable at boot. A `depends_on` won't help, because container start order doesn't guarantee application readiness.

The general lesson transfers directly to production: anything that consumes IdP metadata at startup rather than on demand will fail to start during an identity provider outage, and will need a restart afterward even once the IdP recovers. That turns a five-minute IdP blip into a much longer application outage. It's worth knowing which of your relying parties behave this way *before* you plan a maintenance window.

The portable alternative to host networking, and closer to a real deployment: put both containers on the same Docker network, reference Keycloak by its service name, and add a matching hosts-file entry so the browser resolves the same name to the same server.

### 4. A 404 from typing the wrong URL

Included because it's honest, and because it accounts for a meaningful share of time lost in identity work. When something in a redirect chain fails, the first hypothesis should be that the URL is wrong, not that the protocol is broken.

---

## The part that actually matters: attributes

Here's the first successful assertion, straight out of the SP:

```json
{
  "aud": "http://localhost:9009",
  "iss": "http://localhost:9009",
  "sub": "G-377a8e1d-1aab-4540-8562-ab085a7fad68",
  "attr": {
    "Role": [
      "uma_authorization",
      "manage-account-links",
      "offline_access",
      "view-profile",
      "default-roles-lab",
      "manage-account"
    ],
    "SessionIndex": ["ea589ca5-0293-49c1-afb6-972bbdca7b24::..."]
  },
  "saml-session": true
}
```

Authentication succeeded. And the assertion contains essentially nothing an application could use.

No email. No username. No display name. Just Keycloak's own built-in roles, emitted under an attribute literally named `Role` with the basic name format.

This is the gap that breaks migrations. ADFS deployments accumulate claim rules over years, often written by someone who has since left, and applications quietly depend on them. Keycloak sends almost nothing until you configure it to, and the failure mode isn't a login error. It's a successful login followed by an application that can't find a user record, or renders a blank profile, or throws a null reference somewhere deep in a request handler.

### Naming is the second half of the problem

ADFS emits claims as schema URIs:

```
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
http://schemas.microsoft.com/ws/2008/06/identity/claims/role
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn
```

Keycloak's defaults use short basic-format names. An application matching on the full URI will not find an attribute named `email`, even though the value is right there in the assertion.

So a mapper isn't just about *sending* the attribute. It's about sending it under the exact name and name format the relying party already expects. Adding a User Property mapper for email, with the SAML attribute name set to the ADFS URI and the name format set to URI Reference, produces:

```json
"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress": [
  "sysop@temp.com"
]
```

Now the application finds what it's looking for, and no application-side change was required. That's the goal of a well-executed migration: the identity provider changes, and nothing downstream has to.

Capturing the existing claim rules from the ADFS side is therefore the highest-value pre-migration artifact. Exporting relying party trusts and their claim rules gives you the specification you're building against, and it's a far better source than asking application owners what their app needs, because they usually don't know.

---

## NameID: the subtle one
# What Actually Breaks When You Move a SAML App Off ADFS

Most write-ups about migrating from Active Directory Federation Services to Keycloak stop at "stand up Keycloak, point the app at it, done." That framing is why migrations slip. Authentication is rarely the hard part. A SAML login flow will usually work on the first or second attempt. What breaks is everything *around* the login: the identifier the application uses to recognize a returning user, and the attributes it expects to find in the assertion.

Both of those silently change when you swap identity providers. Neither produces an error message that points at the real cause.

This is a walkthrough of a lab I built to isolate those failure modes, the four distinct ways it broke along the way, and why each one maps to something that shows up in production cutovers.

---

## The lab

Two containers and a service provider, all local:

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: labpassword
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: labpassword
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
    ports:
      - "8080:8080"
    depends_on:
      - postgres
    restart: unless-stopped

  saml-sp:
    image: ghcr.io/beryju/saml-test-sp
    network_mode: host
    environment:
      SP_ENTITY_ID: saml-test-sp
      SP_ROOT_URL: http://localhost:9009
      SP_METADATA_URL: http://127.0.0.1:8080/realms/lab/protocol/saml/descriptor
    restart: unless-stopped

volumes:
  pgdata:
```

Postgres rather than the embedded database, because Keycloak's default H2 store is explicitly not for anything you intend to keep. A dedicated `lab` realm, one test user, one SAML client.

The service provider is a small Go application built on the `crewjam/saml` library. It does one useful thing: after a successful login it dumps the parsed assertion as JSON. Being able to see exactly what arrived, rather than inferring it from whether an app worked, is the entire point of a lab like this.

A note on Keycloak 26: the admin bootstrap environment variables were renamed to `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD`. A large amount of tutorial content still uses the older `KEYCLOAK_ADMIN` form, which now silently fails to create an admin user.

---

## Four ways it broke

### 1. Client signature required

Keycloak's default for a new SAML client is to require that the service provider sign its authentication requests. Many real applications don't sign, and the test SP doesn't either.

The symptom is a rejection at the very start of the flow, before any login page appears. Toggling **Client signature required** off on the client's Keys tab resolves it.

Worth flagging as a deliberate decision rather than a checkbox: in production you generally *want* signed requests. But if the relying party you're migrating never signed requests against ADFS, turning this on during cutover introduces a change the application wasn't asked about.

### 2. Issuer mismatch

This one produced a clean error, and it's the most instructive of the four:

```
response Issuer does not match the IDP metadata (expected "saml-test-sp")
```

The assertion itself was fine. Status Success, correct audience, correct destination, valid signature, role attributes present. The SP rejected it because it had been configured with the IdP's SSO URL and signing certificate manually, and had constructed a synthetic metadata record with the wrong entity ID.

The fix was to stop hand-feeding it and let it fetch Keycloak's real SAML descriptor:

```
http://<host>:8080/realms/<realm>/protocol/saml/descriptor
```

**Why this matters beyond the lab.** Issuer mismatch is one of the most common causes of a broken relying party after an ADFS cutover, for a structural reason: ADFS identifies itself with a URI like

```
http://adfs.company.com/adfs/services/trust
```

while Keycloak uses the realm URL:

```
https://idp.company.com/realms/production
```

Every application that pinned the old issuer, whether in configuration, in a database row, or in a hardcoded constant, stops accepting assertions at cutover. Applications that consume metadata dynamically handle it transparently. Applications with a hand-configured issuer string do not, and the error they surface to users is usually far less specific than the one above.

Inventorying which relying parties hardcode the issuer is a pre-migration task, not a cutover-day discovery.

### 3. Metadata fetched at startup, over IPv6

The SP entered a crash loop:

```
panic: Get "http://localhost:8080/realms/lab/protocol/saml/descriptor":
dial tcp [::1]:8080: connect: connection refused
```

Two things going on. First, `localhost` resolved to the IPv6 loopback, and the published Docker port wasn't listening there. Using `127.0.0.1` explicitly resolved it.

Second, and more interesting: the stack trace shows the metadata fetch happening inside `LoadConfig()` during startup, not lazily on first request as the documentation suggests. That makes the SP hard-dependent on the IdP being reachable at boot. A `depends_on` won't help, because container start order doesn't guarantee application readiness.

The general lesson transfers directly to production: anything that consumes IdP metadata at startup rather than on demand will fail to start during an identity provider outage, and will need a restart afterward even once the IdP recovers. That turns a five-minute IdP blip into a much longer application outage. It's worth knowing which of your relying parties behave this way *before* you plan a maintenance window.

The portable alternative to host networking, and closer to a real deployment: put both containers on the same Docker network, reference Keycloak by its service name, and add a matching hosts-file entry so the browser resolves the same name to the same server.

### 4. A 404 from typing the wrong URL

Included because it's honest, and because it accounts for a meaningful share of time lost in identity work. When something in a redirect chain fails, the first hypothesis should be that the URL is wrong, not that the protocol is broken.

---

## The part that actually matters: attributes

Here's the first successful assertion, straight out of the SP:

```json
{
  "aud": "http://localhost:9009",
  "iss": "http://localhost:9009",
  "sub": "G-377a8e1d-1aab-4540-8562-ab085a7fad68",
  "attr": {
    "Role": [
      "uma_authorization",
      "manage-account-links",
      "offline_access",
      "view-profile",
      "default-roles-lab",
      "manage-account"
    ],
    "SessionIndex": ["ea589ca5-0293-49c1-afb6-972bbdca7b24::..."]
  },
  "saml-session": true
}
```

Authentication succeeded. And the assertion contains essentially nothing an application could use.

No email. No username. No display name. Just Keycloak's own built-in roles, emitted under an attribute literally named `Role` with the basic name format.

This is the gap that breaks migrations. ADFS deployments accumulate claim rules over years, often written by someone who has since left, and applications quietly depend on them. Keycloak sends almost nothing until you configure it to, and the failure mode isn't a login error. It's a successful login followed by an application that can't find a user record, or renders a blank profile, or throws a null reference somewhere deep in a request handler.

### Naming is the second half of the problem

ADFS emits claims as schema URIs:

```
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
http://schemas.microsoft.com/ws/2008/06/identity/claims/role
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn
```

Keycloak's defaults use short basic-format names. An application matching on the full URI will not find an attribute named `email`, even though the value is right there in the assertion.

So a mapper isn't just about *sending* the attribute. It's about sending it under the exact name and name format the relying party already expects. Adding a User Property mapper for email, with the SAML attribute name set to the ADFS URI and the name format set to URI Reference, produces:

```json
"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress": [
  "sysop@temp.com"
]
```

Now the application finds what it's looking for, and no application-side change was required. That's the goal of a well-executed migration: the identity provider changes, and nothing downstream has to.

Capturing the existing claim rules from the ADFS side is therefore the highest-value pre-migration artifact. Exporting relying party trusts and their claim rules gives you the specification you're building against, and it's a far better source than asking application owners what their app needs, because they usually don't know.

---

## NameID: the subtle one

The `sub` value in that first assertion was a transient identifier:

```
G-377a8e1d-1aab-4540-8562-ab085a7fad68
```

It changed on every login. For an application that keys user records on NameID, that means a brand-new account on every sign-in.

The non-obvious part: **the Keycloak client was already configured with a username NameID format.** It was still emitting transient identifiers, because the service provider's authentication request explicitly asked for transient format, and Keycloak honors what the SP requests.

Enabling **Force Name ID Format** makes Keycloak override the request and impose the configured value. After that:

```json
"sub": "sysop@temp.com"
```

Stable across sessions.

This behavior differs meaningfully from ADFS, where NameID is produced by the relying party's claim rules and isn't negotiated with the SP in the same way. An application that never expressed a format preference to ADFS may well express one to Keycloak, and the result is duplicate accounts appearing in production with no error anywhere in the logs to explain them.

---

## What this generalizes to

Reduced to its essentials, an ADFS-to-Keycloak migration is two problems:

**Identifiers must remain stable and identical.** If the value in NameID changes, applications lose the link to existing user records. Verify the format, and verify that the SP can't negotiate you out of it.

**Attributes must arrive under the same names, in the same formats, with the same values.** Keycloak defaults will not match ADFS defaults. Every claim rule on the old side needs a corresponding mapper on the new side.

Everything else, including signing, bindings, certificates, endpoints, and session lifetimes, is real work, but it's work that fails loudly. These two fail quietly, in production, after everyone has agreed the cutover succeeded.

A migration plan that starts with an inventory of relying parties, their claim rules, their NameID formats, and whether they hardcode the issuer will go substantially better than one that starts by standing up Keycloak.

---

## Reproducing this

The compose file above is the whole environment. From a standing start:

1. Bring up the stack and create a realm
2. Create a SAML client with client ID `saml-test-sp` and Master SAML Processing URL `http://localhost:9009/saml/acs`
3. Disable client signature requirement
4. Log in at `http://localhost:9009` and read the assertion
5. Add mappers one at a time, reloading after each, and watch the JSON change

Step 5 is the tightest feedback loop available for learning claim mapping. Every mapper you add appears immediately, in full, with its exact name and format, which is a considerably better teacher than an application that either works or doesn't.

The next layer is federating a real ADFS instance and migrating an actual relying party, rather than a synthetic one. That's a separate write-up.

---

*Adam Pomerantz runs Tessera IT, an identity infrastructure consultancy in southern New Hampshire. Keycloak, Active Directory, and ADFS migrations. Reach him at adam@tesserait.com.*

The `sub` value in that first assertion was a transient identifier:

```
G-377a8e1d-1aab-4540-8562-ab085a7fad68
```

It changed on every login. For an application that keys user records on NameID, that means a brand-new account on every sign-in.

The non-obvious part: **the Keycloak client was already configured with a username NameID format.** It was still emitting transient identifiers, because the service provider's authentication request explicitly asked for transient format, and Keycloak honors what the SP requests.

Enabling **Force Name ID Format** makes Keycloak override the request and impose the configured value. After that:

```json
"sub": "sysop@temp.com"
```

Stable across sessions.

This behavior differs meaningfully from ADFS, where NameID is produced by the relying party's claim rules and isn't negotiated with the SP in the same way. An application that never expressed a format preference to ADFS may well express one to Keycloak, and the result is duplicate accounts appearing in production with no error anywhere in the logs to explain them.

---

## What this generalizes to

Reduced to its essentials, an ADFS-to-Keycloak migration is two problems:

**Identifiers must remain stable and identical.** If the value in NameID changes, applications lose the link to existing user records. Verify the format, and verify that the SP can't negotiate you out of it.

**Attributes must arrive under the same names, in the same formats, with the same values.** Keycloak defaults will not match ADFS defaults. Every claim rule on the old side needs a corresponding mapper on the new side.

Everything else, including signing, bindings, certificates, endpoints, and session lifetimes, is real work, but it's work that fails loudly. These two fail quietly, in production, after everyone has agreed the cutover succeeded.

A migration plan that starts with an inventory of relying parties, their claim rules, their NameID formats, and whether they hardcode the issuer will go substantially better than one that starts by standing up Keycloak.

---

## Reproducing this

The compose file above is the whole environment. From a standing start:

1. Bring up the stack and create a realm
2. Create a SAML client with client ID `saml-test-sp` and Master SAML Processing URL `http://localhost:9009/saml/acs`
3. Disable client signature requirement
4. Log in at `http://localhost:9009` and read the assertion
5. Add mappers one at a time, reloading after each, and watch the JSON change

Step 5 is the tightest feedback loop available for learning claim mapping. Every mapper you add appears immediately, in full, with its exact name and format, which is a considerably better teacher than an application that either works or doesn't.

The next layer is federating a real ADFS instance and migrating an actual relying party, rather than a synthetic one. That's a separate write-up.

---

*Adam Pomerantz runs Tessera IT, an identity infrastructure consultancy in southern New Hampshire. Keycloak, Active Directory, and ADFS migrations. Reach him at adam@tesserait.com.*


ADFS emits claims as schema URIs:

```
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
http://schemas.microsoft.com/ws/2008/06/identity/claims/role
http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn
```

Keycloak's defaults use short basic-format names. An application matching on the full URI will not find an attribute named `email`, even though the value is right there in the assertion.

So a mapper isn't just about *sending* the attribute. It's about sending it under the exact name and name format the relying party already expects. Adding a User Property mapper for email, with the SAML attribute name set to the ADFS URI and the name format set to URI Reference, produces:

```json
"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress": [
  "sysop@temp.com"
]
```

Now the application finds what it's looking for, and no application-side change was required. That's the goal of a well-executed migration: the identity provider changes, and nothing downstream has to.

Capturing the existing claim rules from the ADFS side is therefore the highest-value pre-migration artifact. Exporting relying party trusts and their claim rules gives you the specification you're building against, and it's a far better source than asking application owners what their app needs, because they usually don't know.

---

## NameID: the subtle one

The `sub` value in that first assertion was a transient identifier:

```
G-377a8e1d-1aab-4540-8562-ab085a7fad68
```

It changed on every login. For an application that keys user records on NameID, that means a brand-new account on every sign-in.

The non-obvious part: **the Keycloak client was already configured with a username NameID format.** It was still emitting transient identifiers, because the service provider's authentication request explicitly asked for transient format, and Keycloak honors what the SP requests.

Enabling **Force Name ID Format** makes Keycloak override the request and impose the configured value. After that:

```json
"sub": "sysop@temp.com"
```

Stable across sessions.

This behavior differs meaningfully from ADFS, where NameID is produced by the relying party's claim rules and isn't negotiated with the SP in the same way. An application that never expressed a format preference to ADFS may well express one to Keycloak, and the result is duplicate accounts appearing in production with no error anywhere in the logs to explain them.

---

## What this generalizes to

An ADFS-to-Keycloak migration comes down to two problems:

**Identifiers must remain stable and identical.** If the value in NameID changes, applications lose the link to existing user records. Verify the format, and verify that the SP can't negotiate you out of it.

**Attributes must arrive under the same names, in the same formats, with the same values.** Keycloak defaults will not match ADFS defaults. Every claim rule on the old side needs a corresponding mapper on the new side.

Everything else, including signing, bindings, certificates, endpoints, and session lifetimes, is real work, but it's work that fails loudly. These two fail quietly, in production, after everyone has agreed the cutover succeeded.

A migration plan that starts with an inventory of relying parties, their claim rules, their NameID formats, and whether they hardcode the issuer will go substantially better than one that starts by standing up Keycloak.

---

## Reproducing this

The early compose file above is enough to reproduce everything in this write-up. For the full setup, including TLS and the ADFS side, use `lab/docker-compose.yml` and the README. From a standing start:

1. Bring up the stack and create a realm
2. Create a SAML client with client ID `saml-test-sp` and Master SAML Processing URL `http://localhost:9009/saml/acs`
3. Disable client signature requirement
4. Log in at `http://localhost:9009` and read the assertion
5. Add mappers one at a time, reloading after each, and watch the JSON change

Step 5 is the tightest feedback loop available for learning claim mapping. Every mapper you add appears immediately, in full, with its exact name and format, which is a considerably better teacher than an application that either works or doesn't.

The next layer is federating a real ADFS instance and migrating an actual relying party, rather than a synthetic one. That's a separate write-up.

---

*Adam Pomerantz runs Tessera IT, an identity infrastructure consultancy in southern New Hampshire. Keycloak, Active Directory, and ADFS migrations. Reach him at adam@tesserait.com.*
