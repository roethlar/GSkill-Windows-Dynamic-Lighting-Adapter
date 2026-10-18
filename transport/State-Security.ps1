# Shared by the elevated installer and uninstaller. No changes occur on import.
function Assert-RoyalPlainPath([string]$Path) {
    $current = [System.IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a reparse-point state path: $current"
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Set-RoyalStateAcl([string]$Path, [bool]$Directory) {
    Assert-RoyalPlainPath $Path
    $admin = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $users = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    if ($Directory) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetOwner($admin)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($admin, $system)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', $inheritance, 'None', 'Allow')))
    }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', $inheritance, 'None', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-RoyalStateAcl $Path
}

function Assert-RoyalStateAcl([string]$Path) {
    Assert-RoyalPlainPath $Path
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-32-544','S-1-5-18')) { throw "State path has an untrusted owner: $Path" }
    if (!$acl.AreAccessRulesProtected) { throw "State path inherits permissions: $Path" }
    $readOnly = [int][System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [int][System.Security.AccessControl.FileSystemRights]::Synchronize
    $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.IdentityReference.Value -in @('S-1-5-32-544','S-1-5-18')) { continue }
        if ($rule.IdentityReference.Value -ne 'S-1-5-32-545' -or (([int]$rule.FileSystemRights -band (-bnot $readOnly)) -ne 0)) {
            throw "State path permits access outside the administrators/SYSTEM/Users-read policy: $Path"
        }
    }
}
