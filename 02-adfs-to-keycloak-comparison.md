# Migrating a SAML Application from ADFS to Keycloak: A Claim-by-Claim Comparison

The usual way to validate an identity migration is to move an application and see whether people can still log in. That test passes almost immediately, and it hides most of what actually breaks.

A better test is to run both identity providers at once, point two copies of the same application at them, and compare the assertions side by side. Everything that differs is either something you need to fix or something you need to tell the application owner about. Nothing is left to discover in production.

This is a walkthrough of that setup. Active Directory and ADFS on one side, Keycloak federated to the same directory on the other, one application, two live SAML flows. It covers what matched, what didn't, and why each difference exists.

The lab that preceded this, standing up Keycloak and getting a first SAML flow working, is a separate write-up. This one starts where that one ended.

---

## The environment

Two identity providers, one directory, two instances of the same service provider:

* **Windows Server 2022** running AD DS and ADFS for `corp.lab`
* **Active Directory** populated with 50 users across eight department OUs, plus departmental, application, and role groups with deliberate nesting
* **Keycloak 26** on Postgres, federated to the same directory over LDAP
* **Two SAML SPs**, small Go applications built on `crewjam/saml`, one trusting ADFS and one trusting Keycloak, each dumping its parsed assertion as JSON

The directory structure matters more than it might appear. A flat set of users and groups will not surface the interesting failures. The lab domain was built with:

```
corp.lab
└── OU=Corp
    ├── OU=Users            → 8 department OUs, 50 users
    ├── OU=Groups
    │   ├── OU=Departmental → SEC-Dept-IT, SEC-Dept-Engineering, ...
    │   ├── OU=Application  → APP-Wiki-Users, APP-Wiki-Editors, ...
    │   └── OU=Role         → ROLE-AllStaff, ROLE-Managers, ...
    ├── OU=ServiceAccounts  → svc-keycloak (LDAP bind account)
    └── OU=Admin
```

and with entitlement nesting that mirrors how real organizations accumulate access over time:

```
SEC-Dept-IT ─┐
             ├─→ APP-Wiki-Editors ──→ APP-Wiki-Users
SEC-Dept-Eng ─┘
```

The test user, `clindqvist`, is a direct member of `SEC-Dept-IT` and nothing else wiki-related. Whether she ends up with wiki access depends entirely on whether the identity provider resolves nesting.

---

## The ADFS side: the "before" state

The relying party trust uses claim rules that would be unremarkable in any real deployment:

```
@RuleName = "LDAP Attributes"
c:[Type == ".../claims/windowsaccountname", Issuer == "AD AUTHORITY"]
=> issue(store = "Active Directory",
   types = (".../claims/emailaddress",
            ".../claims/upn",
            ".../claims/givenname",
            ".../claims/surname",
            ".../claims/role"),
   query = ";mail,userPrincipalName,givenName,sn,tokenGroups;{0}",
   param = c.Value);
```

The important token in that rule is **`tokenGroups`**. It is not an ordinary LDAP attribute. The domain controller computes it, and it returns the user's full transitive group membership, including groups reached through nesting and including the user's primary group.

That single word is responsible for most of what follows.

The resulting assertion:

```json
{
  "sub": "christine.lindqvist@corp.lab",
  "attr": {
    ".../claims/role": [
      "Domain Users", "SEC-Dept-IT", "APP-Keycloak-Admins",
      "APP-Wiki-Users", "APP-Wiki-Editors", "APP-VPN-Users",
      "APP-Timesheet-Users", "ROLE-AllStaff"
    ],
    ".../claims/emailaddress": ["christine.lindqvist@corp.lab"],
    ".../claims/givenname": ["Christine"],
    ".../claims/surname": ["Lindqvist"],
    ".../claims/upn": ["christine.lindqvist@corp.lab"]
  }
}
```

Eight groups. `APP-Wiki-Users` and `APP-Wiki-Editors` are both present despite no direct membership.

---

## Getting there: three failures worth documenting

### ADFS rejects the request outright over NameID format

The first attempt against ADFS produced no assertion at all:

```
urn:oasis:names:tc:SAML:2.0:status:Requester
  urn:oasis:names:tc:SAML:2.0:status:InvalidNameIDPolicy
```

The SP's AuthnRequest asked for `transient` NameID format. The ADFS claim rule issued NameID with `emailAddress` format. ADFS could not satisfy the requested policy, so it refused the entire request.

Keycloak, given the identical request, behaved differently. It silently complied with the requested format and returned a transient identifier that changed on every login. No error, no warning. The application would have created a new user record per sign-in, and the problem would have surfaced days later as duplicate accounts.

Same protocol, opposite philosophies. ADFS fails loudly at the front door. Keycloak fails quietly in the user table. When migrating in either direction, this is the first thing to check, because only one of the two directions produces an error you can see.

For the record, resolving it on the Keycloak side means setting the NameID format on the client and also enabling **Force Name ID Format**, which tells Keycloak to override what the SP requested rather than honor it. The format setting alone does nothing if the SP asks for something else.

### ADFS prefix-matches ACS URLs strictly

Adding a second SP instance on a different port produced:

```
MSIS3200: No AssertionConsumerService is configured on the relying party trust
that is a prefix match of the AssertionConsumerService URL
'https://sp.lab:9010/saml/acs' specified by the request.
```

Every ACS endpoint must be registered on the trust explicitly. Keycloak, by contrast, accepts a wildcard redirect URI like `https://sp.lab:9009/*` and matches anything underneath it.

This asymmetry produces a specific migration risk. Teams moving to Keycloak tend to configure the permissive wildcard because it is easier and it works, without noticing they have loosened a constraint ADFS was enforcing. The migration succeeds, and the security posture quietly degrades. Registering exact ACS URLs in Keycloak is a small amount of extra work and preserves the original behavior.

Also worth knowing: `Set-AdfsRelyingPartyTrust -SamlEndpoint` replaces the entire endpoint collection rather than appending to it. Both endpoints have to be passed together.

### Clock skew, and why identity infrastructure lives on NTP

The lab VM had drifted ten days behind the host. SAML assertions carry `NotBefore` and `NotOnOrAfter` conditions typically spanning about five minutes, so every assertion the IdP issued was invalid on arrival.

The failure mode is unhelpful. Signature validation passes, the assertion parses cleanly, and the SP rejects it for reasons that do not obviously point at the clock. On a domain controller with no external DNS forwarders, `w32tm` cannot reach a time source either, so the clock silently stays wrong.

This is not a lab artifact. It is why production identity infrastructure is always on synchronized time, and why "it worked yesterday" is a recognizable symptom when a hypervisor host drifts.

---

## The Keycloak side: reproducing the behavior

### LDAP federation

Keycloak connects to the same directory using a dedicated read-only bind account:

* **Vendor:** Active Directory
* **Users DN:** `OU=Users,OU=Corp,DC=corp,DC=lab`
* **Username LDAP attribute:** `sAMAccountName`
* **Search scope:** Subtree
* **Edit mode:** READ_ONLY

Subtree scope is required, not optional. With users distributed across eight department OUs, a one-level search returns nothing.

### The group mapper, where nesting is won or lost

Two settings on the group mapper determine whether entitlements survive the migration.

**User Groups Retrieve Strategy: `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE_RECURSIVELY`**

This is the Active Directory specific strategy that uses the `LDAP_MATCHING_RULE_IN_CHAIN` operator to resolve nesting server-side. It is Keycloak's closest equivalent to `tokenGroups`. The default strategy returns direct membership only.

If this is left at the default, `clindqvist` receives `SEC-Dept-IT` and loses both wiki groups. Authentication still succeeds. The application still loads. She simply cannot access the wiki anymore, and nothing in any log explains why.

**Preserve Group Inheritance: Off**

Keycloak models groups as a strict tree, where each group has at most one parent. Active Directory group nesting is a general graph. In this directory, `SEC-Dept-IT` and `SEC-Dept-Engineering` both nest into `APP-Wiki-Editors`, which is a diamond, and the sync fails with inheritance enabled.

Turning it off imports the groups flat. Membership is still resolved correctly, but Keycloak no longer knows that `APP-Wiki-Editors` sits inside `APP-Wiki-Users`. For emitting claims this is fine. For anyone planning to manage entitlements in Keycloak afterward, it is a real structural loss and worth raising explicitly before cutover rather than after.

This is a genuine data model mismatch between the two systems, not a configuration mistake.

### Claim mappers

Three of the five claims are straightforward User Property mappers: email, given name, surname. Each is configured with the full ADFS schema URI as the SAML attribute name and the name format set to URI Reference. Using Keycloak's default short names in Basic format would deliver the correct values under names no ADFS-era application is looking for.

**UPN requires two mappers, in different parts of the product.** `userPrincipalName` is not one of Keycloak's built-in user properties, so it first has to be pulled into a user attribute by a `user-attribute-ldap-mapper` on the federation provider, then emitted by a User Attribute protocol mapper on the client. A common trap here is setting the LDAP attribute name to `upn`, the internal name, rather than `userPrincipalName`, which is what the attribute is actually called in Active Directory. The result is an empty claim with no error.

**Groups are emitted with a Group list mapper**, with **Full group path off**. With it on, Keycloak prefixes values with a slash (`/APP-Wiki-Users`), and applications matching against the ADFS-era value will not match.

A note on modeling. It is tempting to map AD groups onto Keycloak *roles* rather than groups, partly because the SAML claim is named `role`. That naming is a coincidence. It is the claim type ADFS uses, unrelated to Keycloak's internal role concept. Groups map directly onto what LDAP federation already synced. Roles would mean maintaining a hand-built translation layer for every group in the directory. Redesigning an entitlement model is legitimate, valuable work, but it belongs in a separate engagement. Doing it during a cutover makes it impossible to tell which system caused which behavior change.

---

## The comparison

Same user, same application, both providers:

| Claim | ADFS | Keycloak |
|---|---|---|
| NameID (`sub`) | christine.lindqvist@corp.lab | christine.lindqvist@corp.lab |
| emailaddress | yes | yes |
| givenname | yes | yes |
| surname | yes | yes |
| upn | yes | yes |
| role | 8 groups | 7 groups |
| `Role` (extra) | not sent | 6 Keycloak internal roles |

Four claims matched exactly. Two differences remained.

### Keycloak emits its own internal roles

Alongside the correctly mapped role claim, the Keycloak assertion carried a second attribute named `Role` containing `uma_authorization`, `manage-account`, `manage-account-links`, `offline_access`, `view-profile`, and `default-roles-lab`.

These come from the `role_list` client scope, which Keycloak assigns to every SAML client by default. ADFS sends nothing comparable.

For an application matching on the exact claim URI, this is harmless noise. For an application that collects all role-like attributes, which is not an unreasonable thing to have written, six entitlements now exist that correspond to nothing in the directory. Removing the `role_list` scope from the client resolves it.

This is worth checking on every migrated client. It is on by default, it is easy to miss, and its impact depends entirely on how the application parses attributes.

### `Domain Users` cannot be synced over LDAP

The one genuinely unresolvable difference.

`Domain Users` is a **primary group** in Active Directory. Primary group membership is not recorded in the `member` attribute. It is derived from the user's `primaryGroupID`. No LDAP query based on `member` will return it, regardless of search base, scope, or retrieval strategy.

ADFS sees it because the domain controller computes `tokenGroups` rather than reading it from an attribute.

In practice this rarely matters, because `Domain Users` contains everyone and is seldom used as a meaningful entitlement. But if an application has a rule keyed on it, that rule stops matching at cutover with no error anywhere. The workaround is a hardcoded attribute mapper adding the value unconditionally, which is defensible precisely because every user is a member by definition.

This is the kind of thing that only surfaces from a claim-level comparison. Testing whether login works would never reveal it.

---

## What this generalizes to

An ADFS to Keycloak migration comes down to four problems.

**Identifiers must stay stable and identical.** NameID format is negotiated between SP and IdP, and the two products negotiate differently. Verify the value, not just that login succeeds.

**Attributes must arrive under identical names and formats.** ADFS schema URIs, URI Reference name format, no path prefixes on group values.

**Nested group membership must be resolved the same way.** This is the one most likely to cause silent access loss, because authentication continues to work perfectly.

**Defaults on both sides must be audited.** Keycloak adds claims ADFS never sent. ADFS enforces constraints Keycloak does not. Neither is visible unless you compare.

Everything else, including bindings, certificates, signing, endpoints, and session lifetimes, fails loudly and gets fixed during testing. These four fail quietly, in production, after everyone has agreed the migration succeeded.

## A note on sequencing

The highest value pre-migration artifact is an export of the existing relying party trusts and their claim rules:

```powershell
Get-AdfsRelyingPartyTrust |
  Select-Object Name, Identifier, IssuanceTransformRules
```

That output is the specification. It is a far better source than asking application owners what their application needs, because they usually do not know. The rules were written years ago by someone who has since moved on.

Reading those rules and translating them by hand is tedious, repetitive, and mechanical, which is a reasonable description of something that should eventually be automated.

---

*Adam Pomerantz runs Tessera IT, an identity infrastructure consultancy in southern New Hampshire. Keycloak, Active Directory, and ADFS migrations. Reach him at adam@tesserait.com.*
