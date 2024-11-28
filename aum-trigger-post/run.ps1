# Make sure that we are using eventGridEvent for parameter binding in Azure function.
param($eventGridEvent, $TriggerMetadata)

# Connecting to the table storage
$StorageAccountName = "rgpatchtest01806d" # Enter the name of the storage account e.g. "BrendgStorage"
$StorageAccountRg = "rg-patch-test-01"
$TableName = "VmState"


$Key = Get-AzStorageAccountKey -ResourceGroupName $StorageAccountRg -Name $StorageAccountName
$StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $Key[0].Value # Connect to the Storage Account
$Table = (Get-AzStorageTable -Context $StorageContext | where {$_.name -eq $TableName}).CloudTable # Connect to the VM State table
$PartitionKey = "1"
$Time = Get-Date

# Install the Resource Graph module from PowerShell Gallery
#  Install-Module -Name Az.ResourceGraph

# $maintenanceRunId = $eventGridEvent.data.CorrelationId
# $resourceSubscriptionIds = $eventGridEvent.data.ResourceSubscriptionIds
$jobIDs= New-Object System.Collections.Generic.List[System.Object]
$preStoppedMachines = Get-AzTableRow -Table $Table -CustomFilter "(State eq 'Started') and (JobId eq 'Ok')"

$preStoppedMachines | ForEach-Object {
    $vmId = $_.Id
    $vmState = $_.State
    $vmRow = $_

    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];

    Write-Output ("Subscription Id: " + $subscriptionId)

    $mute = Set-AzContext -Subscription $subscriptionId
    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute
if ($vmState = "started") {
    Write-Output "Stopping '$($name)' ..."

    $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Set-AzContext -Subscription $sub; Stop-AzVM -ResourceGroupName $resource -Name $vmname -Force -DefaultProfile $context} -ArgumentList $rg, $name, $subscriptionId
    
    $vmRow.State = "Stopping"
    $vmRow.JobId = $newJob.Id
    $vmRow | Update-AzTableRow -Table $Table
    
    $jobIDs.Add($newJob.Id)
}

}

$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish stopping..."
    Wait-Job -Id $jobsList
}

foreach($id in $jobsList)
{
    $vmRow = Get-AzTableRow -Table $Table -CustomFilter "(JobId eq $id) and (State eq 'Stopping')"
    $job = Get-Job -Id $id
    if ($job.Error)
    {
        Write-Output $job.Error
        $vmRow.State = $job.Error
        $vmRow.JobId = "Error"
        $vmRow | Update-AzTableRow -Table $Table
    }
    else {
        $vmRow | Remove-AzTableRow -Table $Table
    }
}