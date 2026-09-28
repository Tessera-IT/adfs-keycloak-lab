<#
    Build-LabDomain.ps1

    Builds a realistic corporate Active Directory structure in corp.lab:
      - Tiered OU hierarchy (users by department, groups by type, admin tier)
      - Department security groups
      - Application entitlement groups, some nested
      - 50 users with department, title, manager, email, and UPN populated

    Run as Domain Admin on the DC. Idempotent enough to re-run safely.

    Edit $DomainDN / $Domain below if your domain is not corp.lab.
#>

Import-Module ActiveDirectory

$Domain     = "corp.lab"
$DomainDN   = "DC=corp,DC=lab"
$RootOU     = "Corp"
$RootOUPath = "OU=$RootOU,$DomainDN"
# Prompted at runtime so no credential is stored in this file.
$Password   = Read-Host -Prompt "Password to set on all lab accounts" -AsSecureString

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-LabOU {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "  OU created: $dn" -ForegroundColor Green
    } else {
        Write-Host "  OU exists:  $dn" -ForegroundColor DarkGray
    }
}

function New-LabGroup {
    param([string]$Name, [string]$Path, [string]$Description, [string]$Scope = "Global")
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Name -GroupScope $Scope -GroupCategory Security `
                    -Path $Path -Description $Description
        Write-Host "  Group created: $Name" -ForegroundColor Green
    } else {
        Write-Host "  Group exists:  $Name" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 1. OU structure
# ---------------------------------------------------------------------------

Write-Host "`n=== Building OU structure ===" -ForegroundColor Cyan

New-LabOU -Name $RootOU -Path $DomainDN

New-LabOU -Name "Users"           -Path $RootOUPath
New-LabOU -Name "Groups"          -Path $RootOUPath
New-LabOU -Name "Computers"       -Path $RootOUPath
New-LabOU -Name "ServiceAccounts" -Path $RootOUPath
New-LabOU -Name "Admin"           -Path $RootOUPath

$Departments = @(
    "Executive","Finance","HumanResources","IT",
    "Sales","Marketing","Engineering","Operations"
)

$UsersOU = "OU=Users,$RootOUPath"
foreach ($dept in $Departments) {
    New-LabOU -Name $dept -Path $UsersOU
}

$GroupsOU = "OU=Groups,$RootOUPath"
New-LabOU -Name "Departmental" -Path $GroupsOU
New-LabOU -Name "Application"  -Path $GroupsOU
New-LabOU -Name "Role"         -Path $GroupsOU

$ComputersOU = "OU=Computers,$RootOUPath"
New-LabOU -Name "Workstations" -Path $ComputersOU
New-LabOU -Name "Servers"      -Path $ComputersOU

New-LabOU -Name "PrivilegedAccounts" -Path "OU=Admin,$RootOUPath"

# ---------------------------------------------------------------------------
# 2. Groups
# ---------------------------------------------------------------------------

Write-Host "`n=== Creating groups ===" -ForegroundColor Cyan

$DeptGroupOU = "OU=Departmental,$GroupsOU"
$AppGroupOU  = "OU=Application,$GroupsOU"
$RoleGroupOU = "OU=Role,$GroupsOU"

foreach ($dept in $Departments) {
    New-LabGroup -Name "SEC-Dept-$dept" -Path $DeptGroupOU `
                 -Description "All members of the $dept department"
}

# Application entitlement groups - these are what claim rules key on
$AppGroups = @(
    @{ Name = "APP-Keycloak-Admins";      Desc = "Administrative access to the identity provider" },
    @{ Name = "APP-ERP-ReadOnly";         Desc = "Read-only access to the finance ERP" },
    @{ Name = "APP-ERP-Approvers";        Desc = "Approval rights in the finance ERP" },
    @{ Name = "APP-CRM-Users";            Desc = "Standard CRM access" },
    @{ Name = "APP-CRM-Admins";           Desc = "CRM administrative access" },
    @{ Name = "APP-Wiki-Users";           Desc = "Internal wiki access" },
    @{ Name = "APP-Wiki-Editors";         Desc = "Internal wiki editing rights" },
    @{ Name = "APP-VPN-Users";            Desc = "Remote access VPN" },
    @{ Name = "APP-Timesheet-Users";      Desc = "Timesheet system access" },
    @{ Name = "APP-Timesheet-Approvers";  Desc = "Timesheet approval rights" }
)

foreach ($g in $AppGroups) {
    New-LabGroup -Name $g.Name -Path $AppGroupOU -Description $g.Desc
}

# Role groups - deliberately used as nesting containers
$RoleGroups = @(
    @{ Name = "ROLE-AllStaff";   Desc = "Every employee" },
    @{ Name = "ROLE-Managers";   Desc = "People managers" },
    @{ Name = "ROLE-Executives"; Desc = "Executive leadership" }
)

foreach ($g in $RoleGroups) {
    New-LabGroup -Name $g.Name -Path $RoleGroupOU -Description $g.Desc
}

# ---------------------------------------------------------------------------
# 3. Group nesting
#    Nested membership is the single most common source of surprise when
#    translating ADFS group claims to Keycloak. Build it in deliberately.
# ---------------------------------------------------------------------------

Write-Host "`n=== Nesting groups ===" -ForegroundColor Cyan

$Nesting = @(
    @{ Child = "SEC-Dept-Engineering";  Parent = "APP-Wiki-Editors" },
    @{ Child = "SEC-Dept-IT";           Parent = "APP-Wiki-Editors" },
    @{ Child = "SEC-Dept-Sales";        Parent = "APP-CRM-Users" },
    @{ Child = "SEC-Dept-Marketing";    Parent = "APP-CRM-Users" },
    @{ Child = "SEC-Dept-Finance";      Parent = "APP-ERP-ReadOnly" },
    @{ Child = "APP-Wiki-Editors";      Parent = "APP-Wiki-Users" },
    @{ Child = "APP-CRM-Admins";        Parent = "APP-CRM-Users" },
    @{ Child = "APP-ERP-Approvers";     Parent = "APP-ERP-ReadOnly" },
    @{ Child = "ROLE-Executives";       Parent = "ROLE-Managers" },
    @{ Child = "ROLE-Managers";         Parent = "ROLE-AllStaff" }
)

foreach ($n in $Nesting) {
    try {
        Add-ADGroupMember -Identity $n.Parent -Members $n.Child -ErrorAction Stop
        Write-Host "  $($n.Child) -> $($n.Parent)" -ForegroundColor Green
    } catch {
        Write-Host "  $($n.Child) -> $($n.Parent) (already nested)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 4. Users
# ---------------------------------------------------------------------------

Write-Host "`n=== Creating users ===" -ForegroundColor Cyan

# Format: First, Last, Department, Title, IsManager, IsExec
$People = @(
    @("Margaret","Chen","Executive","Chief Executive Officer",$true,$true),
    @("David","Okafor","Executive","Chief Financial Officer",$true,$true),
    @("Priya","Raman","Executive","Chief Technology Officer",$true,$true),
    @("Thomas","Bergstrom","Executive","Chief Operating Officer",$true,$true),

    @("Angela","Whitfield","Finance","Controller",$true,$false),
    @("Marcus","Delgado","Finance","Senior Accountant",$false,$false),
    @("Sofia","Petrov","Finance","Accounts Payable Specialist",$false,$false),
    @("Brian","Kowalski","Finance","Financial Analyst",$false,$false),
    @("Renee","Sanders","Finance","Payroll Administrator",$false,$false),
    @("Victor","Nakamura","Finance","Staff Accountant",$false,$false),

    @("Denise","Alvarez","HumanResources","HR Director",$true,$false),
    @("Jonathan","Pierce","HumanResources","HR Business Partner",$false,$false),
    @("Kelly","Osei","HumanResources","Recruiter",$false,$false),
    @("Samuel","Rothman","HumanResources","Benefits Coordinator",$false,$false),

    @("Nathan","Brooks","IT","IT Director",$true,$false),
    @("Elena","Vasquez","IT","Systems Administrator",$false,$false),
    @("Ryan","Muthoni","IT","Network Engineer",$false,$false),
    @("Christine","Lindqvist","IT","Identity Engineer",$false,$false),
    @("Omar","Haddad","IT","Help Desk Technician",$false,$false),
    @("Jessica","Tran","IT","Security Analyst",$false,$false),
    @("Peter","Grimaldi","IT","Database Administrator",$false,$false),
    @("Aisha","Bello","IT","Cloud Engineer",$false,$false),

    @("Gregory","Sullivan","Sales","VP of Sales",$true,$false),
    @("Monica","Reyes","Sales","Regional Sales Manager",$true,$false),
    @("Derek","Lindgren","Sales","Account Executive",$false,$false),
    @("Tanya","Mbeki","Sales","Account Executive",$false,$false),
    @("Kyle","Ferraro","Sales","Account Executive",$false,$false),
    @("Heather","Novak","Sales","Sales Development Rep",$false,$false),
    @("Andre","Toussaint","Sales","Sales Development Rep",$false,$false),
    @("Lauren","Whitaker","Sales","Solutions Consultant",$false,$false),
    @("Ibrahim","Qureshi","Sales","Account Manager",$false,$false),
    @("Natalie","Bergeron","Sales","Sales Operations Analyst",$false,$false),

    @("Patrick","Donnelly","Marketing","Marketing Director",$true,$false),
    @("Yuki","Tanaka","Marketing","Content Manager",$false,$false),
    @("Carlos","Mendez","Marketing","Demand Generation Manager",$false,$false),
    @("Rebecca","Sorensen","Marketing","Product Marketing Manager",$false,$false),
    @("Devon","Ashby","Marketing","Graphic Designer",$false,$false),
    @("Simone","Laurent","Marketing","Marketing Analyst",$false,$false),

    @("Alan","Whitcomb","Engineering","VP of Engineering",$true,$false),
    @("Fatima","Zahra","Engineering","Engineering Manager",$true,$false),
    @("Trevor","Nilsson","Engineering","Senior Software Engineer",$false,$false),
    @("Priscilla","Adeyemi","Engineering","Senior Software Engineer",$false,$false),
    @("Julian","Castellanos","Engineering","Software Engineer",$false,$false),
    @("Meredith","Falk","Engineering","Software Engineer",$false,$false),
    @("Hassan","Karim","Engineering","QA Engineer",$false,$false),
    @("Bethany","Cole","Engineering","DevOps Engineer",$false,$false),

    @("Roger","Mancini","Operations","Operations Manager",$true,$false),
    @("Linda","Achebe","Operations","Facilities Coordinator",$false,$false),
    @("Wesley","Fontaine","Operations","Logistics Specialist",$false,$false),
    @("Grace","Halvorsen","Operations","Procurement Specialist",$false,$false)
)

$Created = @()

foreach ($p in $People) {
    $first  = $p[0]; $last = $p[1]; $dept = $p[2]; $title = $p[3]
    $isMgr  = $p[4]; $isExec = $p[5]

    $sam    = ("$($first.Substring(0,1))$last").ToLower()
    $upn    = "$($first.ToLower()).$($last.ToLower())@$Domain"
    $email  = $upn
    $path   = "OU=$dept,$UsersOU"

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Host "  User exists: $sam" -ForegroundColor DarkGray
    } else {
        New-ADUser -Name "$first $last" `
                   -GivenName $first `
                   -Surname $last `
                   -SamAccountName $sam `
                   -UserPrincipalName $upn `
                   -EmailAddress $email `
                   -DisplayName "$first $last" `
                   -Title $title `
                   -Department $dept `
                   -Company "Corp Industries" `
                   -Path $path `
                   -AccountPassword $Password `
                   -Enabled $true `
                   -ChangePasswordAtLogon $false `
                   -PasswordNeverExpires $true
        Write-Host "  User created: $sam ($dept)" -ForegroundColor Green
    }

    # Department + all-staff membership
    Add-ADGroupMember -Identity "SEC-Dept-$dept"   -Members $sam -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "ROLE-AllStaff"    -Members $sam -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "APP-VPN-Users"    -Members $sam -ErrorAction SilentlyContinue
    Add-ADGroupMember -Identity "APP-Timesheet-Users" -Members $sam -ErrorAction SilentlyContinue

    if ($isMgr)  {
        Add-ADGroupMember -Identity "ROLE-Managers"          -Members $sam -ErrorAction SilentlyContinue
        Add-ADGroupMember -Identity "APP-Timesheet-Approvers" -Members $sam -ErrorAction SilentlyContinue
    }
    if ($isExec) {
        Add-ADGroupMember -Identity "ROLE-Executives" -Members $sam -ErrorAction SilentlyContinue
    }

    $Created += [pscustomobject]@{ Sam = $sam; Dept = $dept; IsMgr = $isMgr }
}

# ---------------------------------------------------------------------------
# 5. Targeted entitlements
# ---------------------------------------------------------------------------

Write-Host "`n=== Assigning targeted entitlements ===" -ForegroundColor Cyan

$Targeted = @(
    @{ Group = "APP-Keycloak-Admins"; Members = @("clindqvist","nbrooks","abello") },
    @{ Group = "APP-ERP-Approvers";   Members = @("awhitfield","dokafor") },
    @{ Group = "APP-CRM-Admins";      Members = @("nbergeron","gsullivan") }
)

foreach ($t in $Targeted) {
    foreach ($m in $t.Members) {
        Add-ADGroupMember -Identity $t.Group -Members $m -ErrorAction SilentlyContinue
    }
    Write-Host "  $($t.Group): $($t.Members -join ', ')" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 6. Managers
# ---------------------------------------------------------------------------

Write-Host "`n=== Setting manager relationships ===" -ForegroundColor Cyan

$DeptHeads = @{
    "Finance"        = "awhitfield"
    "HumanResources" = "dalvarez"
    "IT"             = "nbrooks"
    "Sales"          = "gsullivan"
    "Marketing"      = "pdonnelly"
    "Engineering"    = "awhitcomb"
    "Operations"     = "rmancini"
    "Executive"      = "mchen"
}

foreach ($u in $Created) {
    $head = $DeptHeads[$u.Dept]
    if ($head -and $head -ne $u.Sam) {
        Set-ADUser -Identity $u.Sam -Manager $head -ErrorAction SilentlyContinue
    }
}
Write-Host "  Manager attribute populated." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 7. Service account for Keycloak LDAP bind
# ---------------------------------------------------------------------------

Write-Host "`n=== Creating LDAP bind service account ===" -ForegroundColor Cyan

$svcSam = "svc-keycloak"
if (-not (Get-ADUser -Filter "SamAccountName -eq '$svcSam'" -ErrorAction SilentlyContinue)) {
    New-ADUser -Name "svc-keycloak" `
               -SamAccountName $svcSam `
               -UserPrincipalName "$svcSam@$Domain" `
               -DisplayName "Keycloak LDAP Bind Account" `
               -Description "Read-only bind account for Keycloak user federation" `
               -Path "OU=ServiceAccounts,$RootOUPath" `
               -AccountPassword $Password `
               -Enabled $true `
               -PasswordNeverExpires $true `
               -ChangePasswordAtLogon $false
    Write-Host "  Created $svcSam" -ForegroundColor Green
} else {
    Write-Host "  $svcSam already exists" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Users:  $((Get-ADUser -Filter * -SearchBase $UsersOU).Count)"
Write-Host "Groups: $((Get-ADGroup -Filter * -SearchBase $GroupsOU).Count)"
Write-Host "`nAll lab accounts were created with the password you entered at the prompt."
Write-Host "Keycloak bind DN: CN=svc-keycloak,OU=ServiceAccounts,$RootOUPath"
Write-Host "User search base: $UsersOU"
Write-Host "Group search base: $GroupsOU`n"
