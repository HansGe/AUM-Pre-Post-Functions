param($eventGridEvent, $TriggerMetadata)

# # Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | Out-String | Write-Host

# Connecting to the table storage
$StorageAccountName = $env:StorageAccount
$StorageAccountRg = $env:StorageAccountRg
$TableName = $env:TableName


$Key = Get-AzStorageAccountKey -ResourceGroupName $StorageAccountRg -Name $StorageAccountName
$StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $Key[0].Value # Connect to the Storage Account
$Table = (Get-AzStorageTable -Context $StorageContext | where {$_.name -eq $TableName}).CloudTable # Connect to the VM State table
$PartitionKey = "1"
$Time = Get-Date

$maintenanceRunId = $eventGridEvent.data.CorrelationId
$resourceSubscriptionIds = $eventGridEvent.data.ResourceSubscriptionIds

if ($resourceSubscriptionIds.Count -eq 0) {
    Write-Output "Resource subscriptions are not present."
    break
}

Write-Output "Querying ARG to get machine details [MaintenanceRunId=$maintenanceRunId][ResourceSubscriptionIdsCount=$($resourceSubscriptionIds)]"

$argQuery = @"
    maintenanceresources 
    | where type =~ 'microsoft.maintenance/applyupdates'
    | where properties.correlationId =~ '$($maintenanceRunId)'
    | where id has '/providers/microsoft.compute/virtualmachines/'
    | project id, resourceId = tostring(properties.resourceId)
    | order by id asc
"@

Write-Output "Arg Query Used: $argQuery"

$allMachines = [System.Collections.ArrayList]@()
$skipToken = $null

do
{
    $res = Search-AzGraph -Query $argQuery -First 1000 -SkipToken $skipToken -Subscription $resourceSubscriptionIds
    $skipToken = $res.SkipToken
    $allMachines.AddRange($res.Data)
} while ($skipToken -ne $null -and $skipToken.Length -ne 0)
if ($allMachines.Count -eq 0) {
    Write-Output "No Machines were found."
    break
}

$jobIDs= New-Object System.Collections.Generic.List[System.Object]
$startableStates = "stopped" , "stopping", "deallocated", "deallocating"

$allMachines | ForEach-Object {
    $vmId =  $_.resourceId

    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];

    Write-Output ("Subscription Id: " + $subscriptionId)

    $mute = Set-AzContext -Subscription $subscriptionId
    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute

    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $startableStates) {
        Write-Output "Starting '$($name)' ..."

        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Set-AzContext -Subscription $sub; Start-AzVM -ResourceGroupName $resource -Name $vmname -DefaultProfile $context} -ArgumentList $rg, $name, $subscriptionId
        Add-AzTableRow -Table $Table -PartitionKey $PartitionKey -RowKey (Get-Date).Ticks -property @{"JobId"=$newJob.id;"DateTime"=$Time.DateTime;"VmName"=$name;"RgName"=$rg;"SubID"=$subscriptionId;"ID"=$vmId;"State"=$state}
        $jobIDs.Add($newJob.Id)
    } else {
        Write-Output ($name + ": no action taken. State: " + $state) 
    }
}

$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish starting..."
    Wait-Job -Id $jobsList
}

foreach($id in $jobsList)
{
    $vmRow = Get-AzTableRow -Table $Table -CustomFilter "(JobId eq $id)"
    $job = Get-Job -Id $id
    if ($job.Error)
    {
        Write-Output $job.Error
        $vmRow.State = $job.Error
        $vmRow.JobId = "Error"
        $vmRow | Update-AzTableRow -Table $Table
    }
    else {
        $vmRow.State = "Started"
        $vmRow.JobId = "Ok"
        $vmRow | Update-AzTableRow -Table $Table
    }
}