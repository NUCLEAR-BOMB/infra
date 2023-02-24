do {
  $ping = test-connection -comp "s3.amazonaws.com" -count 1 -Quiet
} until ($ping)

$userdata = Invoke-WebRequest -Uri "http://169.254.169.254/latest/user-data" -UseBasicParsing
$env:CE_ENV = $userdata -as [string]
$DEPLOY_DIR = "/compilerexplorer"
$CE_ENV = $env:CE_ENV
$CE_USER = "ce"
$env:PATH = "$env:PATH;C:\Program Files\Amazon\AWSCLIV2"

function GetBetterHostname {
    $meta = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/hostname" -UseBasicParsing
    return $meta -as [string] -replace ".ec2.internal",""
}

$betterComputerName = GetBetterHostname
Write-Host "AWS Hostname $betterComputerName"

function update_code {
    Write-Host "Current environment $CE_ENV"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/compiler-explorer/version/$CE_ENV" -OutFile "/tmp/s3key.txt"

    $S3_KEY = Get-Content -Path "/tmp/s3key.txt"

    # should not be needed, but just in case we copy pasted the file
    $S3_KEY = $S3_KEY -replace ".tar.xz","zip"

    get_released_code -URL "https://s3.amazonaws.com/compiler-explorer/$S3_KEY"
}

function get_released_code {
    param (
        $URL
    )

    Write-Host "Download build from: $URL"
    Invoke-WebRequest -Uri $URL -OutFile "/tmp/build.zip"

    Write-Host "Unzipping"
    Remove-Item -Path "/compilerexplorer" -Force -Recurse
    New-Item -Path "./" -Name "compilerexplorer" -ItemType "directory" -Force
    Expand-Archive -Path "/tmp/build.zip" -DestinationPath $DEPLOY_DIR
}

function GetConf {
    Param(
        $Name
    )

    try {
        return (aws ssm get-parameter --name "$Name" | ConvertFrom-Json).Parameter.Value
    }
    catch {
        return ""
    }
}

function GetLogHost {
    return GetConf -Name "/compiler-explorer/logDestHost";
}

function GetLogPort {
    return GetConf -Name "/compiler-explorer/logDestPort";
}

function DenyAccessByCE {
    param (
        $Path
    )

    $ACL = Get-ACL -Path $Path
    $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("ce", "FullControl", "Deny")
    $ACL.AddAccessRule($AccessRule)
    $ACL | Set-Acl -Path $Path
}

function GeneratePassword {
    $pass = -join ((1..15) | %{get-random -minimum 33 -maximum 127 | %{[char]$_}}) + -join ((1..2) | %{get-random -minimum 33 -maximum 48 | %{[char]$_}}) -replace "c","" -replace "e", "" -replace "C","" -replace "E", "";
    $securePassword = ConvertTo-SecureString $pass -AsPlainText -Force;
    return $securePassword;
}

function RecreateUser {
    param(
        $securePassword
    )

    $exists = (Get-LocalUser $CE_USER -ErrorAction Ignore) -as [bool];
    if ($exists) {
        Remove-LocalUser $CE_USER;
    }

    New-LocalUser -User $CE_USER -Password $securePassword -PasswordNeverExpires -FullName "CE" -Description "Special user for running Compiler Explorer";
    Add-LocalGroupMember -Group "Users" -Member $CE_USER;

    ConfigureUserRights -SID (Get-LocalUser $CE_USER).SID
}

function ConfigureUserRights {
    param(
        [String] $SID
    )

    $tmpfile = "c:\tmp\secpol.cfg"
    secedit /export /cfg $tmpfile
    $secpol = (Get-Content $tmpfile)

    $Value = $secpol | Where-Object{ $_ -like "SeBatchLogonRight*" }
    $Index = [array]::IndexOf($secpol,$Value)

    $NewValue = $Value + ",*" + $SID
    $secpol.item($Index) = $NewValue

    $Value = $secpol | Where-Object{ $_ -like "MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters\AllowInsecureGuestAuth" }
    $Index = [array]::IndexOf($secpol,$Value)
    if ($Index -eq -1) {
        $Index = [array]::IndexOf($secpol, "[Registry Values]")
        $idx2 = $Index + 1
        $NewValue = "MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters\AllowInsecureGuestAuth=4,1"
        $newpol = $secpol[0..$Index]
        $newpol += ($NewValue)
        $newpol += $secpol[$idx2..$secpol.Length]
        $secpol = $newpol
    } else {
        $NewValue = "MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters\AllowInsecureGuestAuth=4,1"
        $secpol.item($Index) = $NewValue
    }

    $secpol | out-file $tmpfile -Force
    secedit /configure /db c:\windows\security\local.sdb /cfg $tmpfile
    Remove-Item -Path $tmpfile

    gpupdate /Force
}

function InstallAsService {
    param(
        [string] $Name,
        [string] $Exe,
        [array] $Arguments,
        [string] $WorkingDirectory,
        [PSCredential] $User,
        [securestring] $Password
    )

    $tmplog = "C:/tmp/log"
    Write-Host "nssm.exe install $Name $Exe"
    /nssm/win64/nssm.exe install $Name $Exe
    if ($Arguments.Length -gt 0) {
        Write-Host "nssm.exe set $Name AppParameters" ($Arguments -join " ")
        /nssm/win64/nssm.exe set $Name AppParameters ($Arguments -join " ")
    }
    Write-Host "nssm.exe set $Name AppDirectory $WorkingDirectory"
    /nssm/win64/nssm.exe set $Name AppDirectory $WorkingDirectory
    Write-Host "nssm.exe set $Name AppStdout $tmplog/$Name-svc.log"
    /nssm/win64/nssm.exe set $Name AppStdout "$tmplog/$Name-svc.log"
    Write-Host "nssm.exe set $Name AppStderr $tmplog/$Name-svc.log"
    /nssm/win64/nssm.exe set $Name AppStderr "$tmplog/$Name-svc.log"

    Write-Host "nssm.exe set $Name AppExit Default Exit"
    /nssm/win64/nssm.exe set $Name AppExit Default Exit

    $Username = $Credential.GetNetworkCredential().Username
    $PlainTextPassword = ConvertFrom-SecureString -SecureString $Password -AsPlainText

    Write-Host "nssm.exe set $Name ObjectName $env:COMPUTERNAME\$Username ..."
    /nssm/win64/nssm.exe set $Name ObjectName "$env:COMPUTERNAME\$Username" "$PlainTextPassword"

    Write-Host "nssm.exe start $Name"
    /nssm/win64/nssm.exe start $Name
}

function InstallCERunTask {
    param(
        [PSCredential] $Credential,
        [securestring] $Password,
        [string] $CeEnv
    )

    $runargs = ("c:\tmp\infra\init\run.ps1","-LogHost",(GetLogHost),"-LogPort",(GetLogPort),"-CeEnv",$CeEnv) -join " "

    InstallAsService -Name "ce" -Exe "C:\Program Files\PowerShell\7\pwsh.exe" -WorkingDirectory "C:\tmp" -Arguments $runargs -User $Credential -Password $Password
}

function CreateCredAndRun {
    $pass = GeneratePassword;
    RecreateUser $pass;
    $credential = New-Object System.Management.Automation.PSCredential($CE_USER,$pass);
    DenyAccessByCE -Path "C:\Program Files\Grafana Agent\agent-config.yaml"

    InstallCERunTask -Credential $credential -Password $pass -CeEnv $CE_ENV
}

function GetLatestCEWrapper {
    Write-Host "Fetching latest CEWrapper.exe"
    Copy-Item -Path "Y:/cewrapper/cewrapper.exe" -Destination "/tmp/cewrapper.exe"
    New-Item -Path "/cewrapper" -ItemType Directory -Force
    Move-Item -Path "/tmp/cewrapper.exe" -Destination "/cewrapper/cewrapper.exe" -Force
}

function InitializeAgentConfig {
    Write-Host "Setting up Grafana Agent"
    $config = Get-Content -Path "/tmp/infra/grafana/agent-win.yaml"
    $config = $config.Replace("@HOSTNAME@", $betterComputerName)
    $config = $config.Replace("@ENV@", $CE_ENV)
    $prom_pass = ""
    try {
        $prom_pass = GetConf -Name "/compiler-explorer/promPassword"
    } catch {
    }
    $config = $config.Replace("@PROM_PASSWORD@", $prom_pass)
    Set-Content -Path "C:\Program Files\Grafana Agent\agent-config.yaml" -Value $config
}

function MountY {
    $exists = (Get-SmbMapping Y:) -as [bool]
    if ($exists) {
        Write-Host "Already mapped"
        return
    }

    while (-not $exists) {
        try {
            Write-Host "Mapping Y:"
            $exists = (New-SmbMapping -LocalPath 'Y:' -RemotePath '\\172.30.0.29\winshared') -as [bool]
        } catch {
        }
    }
}

function UnMountY {
     Remove-SmbMapping -LocalPath 'Y:' -Force
}

MountY

GetLatestCEWrapper

UnMountY

InitializeAgentConfig

update_code

# todo: this should be configured into the build
Write-Host "Installing properties files"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/compiler-explorer/windows-docker/main/c++.win32.properties" -OutFile "$DEPLOY_DIR/etc/config/c++.amazonwin.properties"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/compiler-explorer/windows-docker/main/pascal.win32.properties" -OutFile "$DEPLOY_DIR/etc/config/pascal.amazonwin.properties"

netsh advfirewall firewall add rule name="TCP Port 80" dir=in action=allow protocol=TCP localport=80

CreateCredAndRun