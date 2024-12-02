param($eventGridEvent, $TriggerMetadata)

Function Set-AVDHostPoolAutoScaling {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ScalingPlanName,
        [Parameter(Mandatory = $true)]
        [string]$HostPoolResourceId,
        [Parameter(Mandatory = $true)]
        [bool]$EnableAutoScale
    )
    Begin {
        #To be filled later if needed
    }
    Process {
        Update-AzWvdScalingPlan `
            -ResourceGroupName $ResourceGroupName `
            -Name $ScalingPlanName `
            -HostPoolReference @(
            @{
                'hostPoolArmPath'    = $HostPoolResourceId;
                'scalingPlanEnabled' = $EnableAutoScale;
            }
        ) `

    }
}

# # Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | Out-String | Write-Host

# Connecting to the table storage
$StorageAccountName = $env:StorageAccount
$StorageAccountRg = $env:StorageAccountRg
$TableName = $env:TableName
$AvdTableName = $env:AvdTableName


$Key = Get-AzStorageAccountKey -ResourceGroupName $StorageAccountRg -Name $StorageAccountName
$StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $Key[0].Value # Connect to the Storage Account
$Table = (Get-AzStorageTable -Context $StorageContext | where {$_.name -eq $TableName}).CloudTable # Connect to the VM State table
$AvdTable = (Get-AzStorageTable -Context $StorageContext | where {$_.name -eq $AvdTableName}).CloudTable
$PartitionKey = "1"
$Time = Get-Date

$preDisabledScalingPlan = Get-AzTableRow -Table $AvdTable -CustomFilter "(EnabledPre eq 'true')"
$preStoppedMachines = Get-AzTableRow -Table $Table -CustomFilter "(State eq 'Started') and (JobId eq 'Ok')"

$jobIDs= New-Object System.Collections.Generic.List[System.Object]

$preDisabledScalingPlan | ForEach-Object {
    $spId = $_.Id
    $spRg = $_.RgName
    $spName = $_.ScalingPlan
    $hostpoolId = $_.HostPoolId
    $spRow = $_

    Set-AVDHostPoolAutoScaling -ResourceGroupName $spRg -ScalingPlanName $spName -HostPoolResourceId $hostpoolid -EnableAutoScale $true
    $spRow | Remove-AzTableRow -Table $AvdTable
}

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