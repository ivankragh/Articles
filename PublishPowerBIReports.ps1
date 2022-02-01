param (
	[Parameter(Mandatory=$true)][string] $TenantId,
	[Parameter(Mandatory=$true)][string] $ServicePrincipalID,
	[Parameter(Mandatory=$true)][string] $ServicePrincipalSecretValue,
	[Parameter(Mandatory=$true)][string] $PowerBIWorkspaceName,
	[Parameter(Mandatory=$true)][string] $ASConnectionString,
	[Parameter(Mandatory=$false)][string] $TabularObject = "*"
)

<# Set Working Directory #>
$WorkingDirectory = (Join-path -Path (Get-Location).Path -ChildPath 'PBIS');

<# Check if 7zip4Powershell module is installed #>
if (-not(Get-InstalledModule -name 7zip4Powershell -ErrorAction silentlycontinue)) {
	Write-Host "Module 7zip4Powershell does not exist - Installing module";
	Install-Module 7zip4Powershell -Force -Scope CurrentUser;
}
else {
	Write-Host "Module 7zip4Powershell exists";
}

<# Check if MicrosoftPowerBIMgmt module is installed #>
if (-not(Get-InstalledModule -name MicrosoftPowerBIMgmt -ErrorAction silentlycontinue)) {
	Write-Host "Module MicrosoftPowerBIMgmt does not exist - Installing module";
	Install-Module MicrosoftPowerBIMgmt -Force -Scope CurrentUser;
}
else {
	Write-Host "Module MicrosoftPowerBIMgmt exists";
}

<# Generate Credentials for Service Principal #>
$Credentials = New-Object PSCredential $ServicePrincipalID, (ConvertTo-SecureString $ServicePrincipalSecretValue -AsPlainText -Force);
 
<# Connect with Service Principal #>
Connect-PowerBIServiceAccount -ServicePrincipal -Credential $Credentials -Tenant $TenantId;

<# Get workspace information #>
$WorkSpace = ((Invoke-PowerBIRestMethod -Url 'groups' -Method Get | ConvertFrom-Json).value | where {$_.name -eq $PowerBIWorkspaceName});

<# If Workspace does not exist - create workspace #>
If ($WorkSpace.id -eq $null) {
	
	Write-Host "Creating workspace $($PowerBIWorkspaceName)";
    Write-Host "Add Service Principal '$($ServicePrincipalID)' to workspace $($PowerBIWorkspaceName)";

    $NewWorkspaceParameters = @{"name" = "$($PowerBIWorkspaceName)"};
    Invoke-PowerBIRestMethod -Url 'groups?workspaceV2=true' -Method Post -Body ($NewWorkspaceParameters | ConvertTo-Json);

	<# Get workspace information again #>
	$WorkSpace = ((Invoke-PowerBIRestMethod -Url 'groups' -Method Get | ConvertFrom-Json).value | where {$_.name -eq $PowerBIWorkspaceName});
	
}

<# Retrieve Connectionstring from Azure Analysis Service ConnectionString #>
$ASDataSource = ($ASConnectionString.ToString().Split(";") | ConvertFrom-String -Delimiter "=" -PropertyNames PropertyName, PropertyValue) | Where-Object {($_.PropertyName -eq "Data Source")};
$ASDataSource = $ASDataSource.PropertyValue;

<# Prepare each Power BI Report for deployment #>
foreach ($PowerBIReport in Get-ChildItem -Path $WorkingDirectory -Recurse | Where-Object {($_.Directory.Name -notlike "*_temp") -and ($_.Extension -eq ".pbix") -and ($TabularObject -eq "*" -OR $_.Directory.Name -eq $TabularObject)}) {
	TRY {
		<# Declare parameters to be used in copy-update report #>
		$PowerBIReportZip = $PowerBIReport.Name -replace ".pbix", ".zip";
		$PowerBIReportTempFolder = "$($PowerBIReport.Directory.Parent.fullName)\$($PowerBIReport.Directory.Name)_temp";
		$PowerBIReportTempFile = "$($PowerBIReportTempFolder)\$($PowerBIReport.BaseName)";
		$PowerBIReportTempZipFile = "$($PowerBIReportTempFolder)\$($PowerBIReportZip)";
		
		<# Copy report and rename #>
		Write-Host "Copy report $($PowerBIReport.BaseName) to $($PowerBIReport.Directory.Name)_temp folder and rename to $($PowerBIReportZip)"
		
		<# Create new directory for the PowerBIReportTempZipFile #>
		New-Item -ItemType File -Path $PowerBIReportTempZipFile -Force
		Copy-Item $PowerBIReport.FullName -Destination $PowerBIReportTempZipFile -Force;
		
		<# Unpack PowerBIReportZip file to folder structure and remove .zip file #>
		Expand-Archive -Path $PowerBIReportTempZipFile -DestinationPath ($PowerBIReportTempZipFile -replace '.zip', '') -Force;
		Remove-Item -Path $PowerBIReportTempZipFile -Force;
		
		<# Remove security bindings in folder if exists #>
		if (Test-Path -path "$($PowerBIReportTempFile)\SecurityBindings") {
			
			Write-Host "Remove-Item -Path $($PowerBIReportTempFile)\SecurityBindings";
			Remove-Item -Path "$($PowerBIReportTempFile)\SecurityBindings" -Recurse -Force;
		
		};
		
		<# Update Azure Analysis Service Connectionstring #>
		$PowerBIReportConnectionfile = "$($PowerBIReportTempFile)\Connections";
		
		<# Check if report contains ConnectionFile #>
		if (Test-Path $PowerBIReportConnectionfile) {
		
			<# Retrieve Current connectionstring from PowerBI File #>
			$PowerBIConnections = (Get-Content -Path $PowerBIReportConnectionfile | ConvertFrom-Json);
	
			<# Does the file contain a Connections property ? #>
			If ($PowerBIConnections.Connections -ne $null) {
	
				<# Retrieve the ConnectionString from Power BI Report #>
				$PowerBIDataSource = (($PowerBIConnections.Connections).ConnectionString.Split(";") | ConvertFrom-String -Delimiter "=" -PropertyNames PropertyName, PropertyValue) | Where-Object {($_.PropertyName -eq "Data Source")};
				$PowerBIDataSource = $PowerBIDataSource.PropertyValue;
		
				<# Update Power BI Report Connection file #>
				$UpdatedPowerBIReportConnectionfile = (Get-Content -Path $PowerBIReportConnectionfile) -replace $PowerBIDataSource, $ASDataSource;
			
				Write-Host "Update Power BI Report '$($PowerBIReport.BaseName)' Connection file from '$($PowerBIDataSource)' to '$($ASDataSource)' ";
				Set-Content -path $PowerBIReportConnectionfile -value $UpdatedPowerBIReportConnectionfile;
		
			}
		}
		
		<# Create Zip file with changed connectionstring #>
		Write-Host "Create Zip file with changed connectionstring"
		Compress-7Zip -Path $PowerBIReportTempFile -ArchiveFileName $PowerBIReportTempZipFile -Format zip;
		<# Compress-7Zip is used intentionally as the Compress-Archive function breaks the Power BI file. #>
		
		<# If Power BI pbix file already exists - remove before renaming PowerBIReport.zip to PowerBIReport.pbix #>
		if (Test-Path ($PowerBIReportTempZipFile -replace ".zip", ".pbix")) {
			Remove-Item -Path ($PowerBIReportTempZipFile -replace ".zip", ".pbix") -Recurse -Force;
		};
		
		<# Rename Zip-file to PBIX-file #>
		Write-Host "Rename Zip-file to $($PowerBIReport.Name) PBIX-file"
		Rename-Item -Path $PowerBIReportTempZipFile -NewName $PowerBIReport.Name -Force;
		
		<# Remove Power BI Report Temp File: $($PowerBIReportTempFile) #>
		Write-Host "Remove Power BI Report Temp File: $($PowerBIReportTempFile)"
		
		if (Test-Path $PowerBIReportTempFile) {
			Remove-Item -Path $PowerBIReportTempFile -Recurse -Force;
		};
		
		<# Create PublishFolder variable use <TabularObject>_temp\PowerBIReportName #>
		$PublishFolder = "$($PowerBIReportTempFolder)\$($PowerBIReport.Name)";
		
		<# Create or overwrite Report in Power BI Workspace #>
		Write-Host "Publishing $($PowerBIReport.Directory.Name) report: $($PowerBIReport.BaseName) to Workspace: $($PowerBIWorkspaceName)"
		$NewPowerBIReport = (New-PowerBIReport -Path $PublishFolder -Name $PowerBIReport.BaseName -ConflictAction CreateOrOverwrite -Workspace $WorkSpace);

		<# Get Power BI Report DatasetID from #>
        Write-Host "Get Power BI Report DatasetID from $($PowerBIReport.BaseName)"
		$PowerBIDatasetID = (Invoke-PowerBIRestMethod -Url "groups/$($WorkSpace.id)/reports/$($NewPowerBIReport.id)" -Method Get | ConvertFrom-Json);

        <# Ensure that the Power BI report and Dataset is owned by the Service Principal #>
        Write-Host "Ensure that the Power BI report: $($PowerBIReport.BaseName) and Dataset: $($PowerBIDatasetID.DatasetId) is owned by the Service Principal";
		Invoke-PowerBIRestMethod -Url "groups/$($WorkSpace.id)/datasets/$($PowerBIDatasetID.DatasetId)/Default.TakeOver" -Method Post;

	} 
    CATCH {
		$ErrorMessage = $_.exception.message
		Write-Host "<#vso[task.logissue type=error;]Error $($ErrorMessage)";
		THROW;
	}
}