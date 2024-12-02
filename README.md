# AUM-Pre-Post-Functions
- All the Functions need a table on the storage account
- Function needs managed identity
- Managed identity need reader rights on root for resource graph queries
- Managed identity need Virtual Machine Contributor on Virtual machines to start and stop virtual machines
- Managed identity need Storage Table Data Contributor on storage account to write states to the table
- Managed identity need Desktop Virtualization Host Pool Contributor on hostpool to disable the scaling plan