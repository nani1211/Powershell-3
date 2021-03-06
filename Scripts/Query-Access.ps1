<# HEADER
/*=====================================================================
Program Name            : Query-Access.ps1
Purpose                 : Execute query against Access Database
Powershell Version:     : v2.0
Input Data              : N/A
Output Data             : N/A

Originally Written by   : Scott Bass
Date                    : 26SEP2013
Program Version #       : 1.0

=======================================================================

Modification History    :

=====================================================================*/

/*---------------------------------------------------------------------

THIS SCRIPT MUST RUN UNDER x86 (32-bit) POWERSHELL SINCE WE ARE USING
32-BIT MICROSOFT OFFICE.  ONLY THE x86 OLEDB PROVIDER IS INSTALLED!!!

---------------------------------------------------------------------*/
#>

<#
.SYNOPSIS
Query Access Database

.DESCRIPTION
Execute a query against an Access Database

.PARAMETER  SQLQuery
SQL Query to execute

.PARAMETER  Path
Path to Access Database

.PARAMETER  Csv
Output as CSV?  If no, the Dataset Table object is returned to the pipeline

.PARAMETER  Whatif
Echos the SQL query information without actually executing it.

.PARAMETER  Confirm
Asks for confirmation before actually executing the query.

.PARAMETER  Verbose
Prints the SQL query to the console window as it executes it.

.EXAMPLE
.\Query-Access.ps1 "Y:\HBM\_HBM-Common\CDMP\CDMP Management.accdb" "select * from coach" -csv

Description
-----------
Queries the specified Access database with the specified query, outputting data as CSV

.EXAMPLE
.\Query-Access.ps1 -path "Y:\HBM\_HBM-Common\CDMP\CDMP Management.accdb" -query "select * from coach" -csv:$false

Description
-----------
Queries the specified Access database with the specified query, 
returning the Object Table to the pipeline

#>

#region Parameters
[CmdletBinding(SupportsShouldProcess=$true)]
param(
   [Parameter(
      Position=0,
      Mandatory=$true
   )]
   [String]$Path
   ,
   [Alias("query")]
   [Parameter(
      Position=1,
      Mandatory=$true
   )]
   [String]$SqlQuery
   ,
   [Switch]$csv = $true
)
#endregion

$ErrorActionPreference = "Stop"

#$adOpenStatic = 3
#$adLockOptimistic = 3

$SqlConnection = New-Object System.Data.OleDb.OleDbConnection
$SqlConnection.ConnectionString = "Provider=Microsoft.ACE.OLEDB.12.0; Data Source=$path"
$SqlCmd = New-Object System.Data.OleDb.OleDbCommand
$SqlCmd.CommandText = $SqlQuery
$SqlCmd.Connection = $SqlConnection
$SqlAdapter = New-Object System.Data.OleDb.OleDbDataAdapter
$SqlAdapter.SelectCommand = $SqlCmd
$DataSet = New-Object System.Data.DataSet
$nRecs = $SqlAdapter.Fill($DataSet)
$nRecs | Out-Null

# Populate Hash Table
$objTable = $DataSet.Tables[0]

# Return results to console (pipe console output to Out-File cmdlet to create a file)
if ($csv) {
   ($objTable | ConvertTo-CSV -NoTypeInformation) -replace('"','')
} else {
   $objTable
}
