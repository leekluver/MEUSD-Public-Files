# Define variables for user creation
$UserName = "ASB"
$Password = "RedhawksAsb1!"  # Replace with the actual password
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force

# Define variables for PsExec download and execution
$downloadUrl = "https://download.sysinternals.com/files/PSTools.zip"
$destinationFolder = "C:\Temp"
$destinationPath = "$destinationFolder\PSTools.zip"
$extractPath = "$destinationFolder\PSTools"
$psexecPath = Join-Path $extractPath "PsExec.exe"
$commandToRun = 'cmd.exe /C "echo Profile creation triggered & whoami"'

# Define the path to the ASB user's NTUSER.DAT file
$ntuserPath = "C:\Users\$UserName\NTUSER.DAT"
$loadedHive = "HKU\ASBProfile"

# Define registry paths for Edge configurations
$allowListPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLAllowlist"
$blockListPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist"

# Function to log messages
function Write-Log {
    param([string]$message)
    Write-Host $message
}

# Step 1: Create the ASB user if it doesn't exist
if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    Write-Log "Creating user $UserName..."
    New-LocalUser -Name $UserName -Password $securePassword -FullName "ASB User" -Description "User for ASB"
    Add-LocalGroupMember -Group "Users" -Member $UserName
    Set-LocalUser -Name $UserName -PasswordNeverExpires $true
    Write-Log "User $UserName created and configured successfully."
} else {
    Write-Log "User $UserName already exists."
}

# Step 2: Create the C:\Temp directory if it doesn't exist
if (-not (Test-Path -Path $destinationFolder)) {
    New-Item -ItemType Directory -Path $destinationFolder | Out-Null
    Write-Log "Created directory: $destinationFolder"
}

# Step 3: Download PsExec if not already downloaded
if (-not (Test-Path -Path $destinationPath)) {
    Write-Log "Downloading PsExec from Sysinternals..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $destinationPath
    Write-Log "Download completed."
}

# Step 4: Remove the extraction directory if it already exists
if (Test-Path -Path $extractPath) {
    Write-Log "Deleting existing contents of the extraction directory..."
    Remove-Item -Path $extractPath -Recurse -Force
}

# Create the extraction directory if it doesn't exist and extract the ZIP
if (-not (Test-Path -Path $extractPath)) {
    New-Item -ItemType Directory -Path $extractPath | Out-Null
}
Write-Log "Extracting PSTools..."
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
[System.IO.Compression.ZipFile]::ExtractToDirectory($destinationPath, $extractPath)
Write-Log "Extraction completed."

# Step 5: Confirm PsExec is available
if (-not (Test-Path -Path $psexecPath)) {
    Write-Log "Error: PsExec.exe not found after extraction." -ForegroundColor Red
    exit
}

# Step 6: Accept PsExec EULA and trigger profile creation using PsExec
Write-Log "Running PsExec to trigger profile creation for user $UserName..."
$startCommand = "& `"$psexecPath`" /accepteula -u $env:COMPUTERNAME\$UserName -p $Password $commandToRun"

# Use Invoke-Expression to run PsExec and handle output
$result = Invoke-Expression $startCommand 2>&1
Write-Host $result  # Show PsExec output

# Check the exit code of PsExec
if ($LASTEXITCODE -ne 0) {
    Write-Log "PsExec returned an error. Exit code: $LASTEXITCODE" -ForegroundColor Red
} else {
    Write-Log "PsExec executed successfully." -ForegroundColor Green
}

# Step 7: Optionally clean up the downloaded files
Remove-Item -Path $destinationPath -Force
Remove-Item -Path $extractPath -Recurse -Force

# Step 8: Check if the profile was created
$userProfilePath = "C:\Users\$UserName"
if (Test-Path $userProfilePath) {
    Write-Log "User profile for $UserName successfully created at $userProfilePath."
} else {
    Write-Log "Warning: Profile creation for $UserName failed."
}

# Step 9: Configure URL Allow List for Edge
if (-not (Test-Path $allowListPath)) {
    New-Item -Path $allowListPath -Force | Out-Null
}

Set-ItemProperty -Path $allowListPath -Name "1" -Value "https://youthservices.net/sandiego"
Set-ItemProperty -Path $allowListPath -Name "2" -Value "http://youthservices.net/sandiego"
Set-ItemProperty -Path $allowListPath -Name "3" -Value "*.youthservices.net"
Set-ItemProperty -Path $allowListPath -Name "4" -Value "http://*.youthservices.net"
Set-ItemProperty -Path $allowListPath -Name "5" -Value "https://*.youthservices.net"
Set-ItemProperty -Path $allowListPath -Name "6" -Value "http://youthservices.net/*"
Set-ItemProperty -Path $allowListPath -Name "7" -Value "https://youthservices.net/*"
Write-Log "Configured URL Allow List for Microsoft Edge."

# Step 10: Configure URL Block List for Edge
if (-not (Test-Path $blockListPath)) {
    New-Item -Path $blockListPath -Force | Out-Null
}

Set-ItemProperty -Path $blockListPath -Name "1" -Value "*"
Write-Log "Configured URL Block List for Microsoft Edge."

Write-Log "Edge configuration completed successfully."


