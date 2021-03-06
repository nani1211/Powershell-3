<# 
Header goes here...
#>

[CmdletBinding( SupportsShouldProcess = $true,
                ConfirmImpact = 'Medium' )]

param(
    # Tables to process
    [System.Array]
    $Tables
    ,

    # Target
    [ValidateNotNullOrEmpty()]
    [Alias('ts','tgtsvr')]
    [String]
    $TgtServer              = 'SVDCMHPRRLSQD01'
    ,
    [ValidateNotNullOrEmpty()]
    [Alias('tdb','tgtdb')]
    [String]
    $TgtDatabase            = 'RLCS_dev'
    ,
    [ValidateNotNullOrEmpty()]
    [Alias('tsc','tgtsch')]
    [String]
    $TgtSchema              = 'content' 
    ,
    [ValidateNotNullOrEmpty()]
    [Alias('ttb','tgttbl')]
    [String]
    $TgtTable
    ,

    # Script options
    [Alias('timeout')]
    [int]
    $CommandTimeout         = 43200 # 12 hours
    ,
    [switch]
    $Quiet
)

# Source the parameters
# (this may override some command line options)
. \\sascs\linkage\RL_content_snapshots\Powershell\Scripts\RunAll_SqlServerParametersDIU.ps1

# Source the SqlServer function
. \\sascs\linkage\RL_content_snapshots\Powershell\Functions\SqlServerExecCommand.ps1

# Continue this script if an error occurs
$ErrorActionPreference = 'Continue'

# Hardcode verbose output
$VerbosePreference = 'Continue'

# Inline Functions
Function RunPostProcess
{
    # Function to run SqlServer Post-Processing
    [CmdletBinding( SupportsShouldProcess = $true,
                    ConfirmImpact = 'Medium' )]

    param(
        # Source
        [ValidateNotNullOrEmpty()]
        [String]$table
    )

    # Lookup the custom object
    $obj=$ht.Get_Item($table)

    $parms=@()

    if ($obj.TgtServer)          {$parms+='-TgtServer';        $parms+="""{0}""" -f $obj.TgtServer}  # embedded comma
    if ($obj.TgtDatabase)        {$parms+='-TgtDatabase';      $parms+=$obj.TgtDatabase}
    if ($obj.TgtSchema)          {$parms+='-TgtSchema';        $parms+=$obj.TgtSchema}   
    if (! $obj.TgtTable)         {$obj.TgtTable=$table}
                                  $parms+='-TgtTable';         $parms+=$obj.TgtTable

    $CloneTable  = 'zzz_{0}' -f $obj.TgtTable
    
    $OFS="`r`n"  # preserve embedded CRLF's
    $local:SqlQuery = (Get-Content "\\sascs\linkage\RL_content_snapshots\SQLServer\RLCS\PostProcess_${table}.sql") `
                      -f $obj.TgtDatabase, $obj.TgtSchema, $obj.TgtTable, $obj.SrcDatabase, $obj.SrcSchema, $obj.TgtTable, $CloneTable
    $OFS=$null
                                  $parms+='-SqlQuery';         $parms+="""{0}""" -f $SqlQuery  # embedded single quotes
#                                 $parms+='-CommandTimeout';   $parms+=$obj.CommandTimeout
                      
    $msg='For {0}.{1}.{2}' -f $TgtDatabase, $TgtSchema, $table
    if ($PSCmdlet.ShouldProcess($msg,'Post-Processing'))
    {
        Try {
            Invoke-Expression "SqlServerExecCommand $parms"
        }
        Catch {
            $msg = $_.Exception.Message
            Write-Error "Error in Post-Processing..."
            Write-Error ($msg)
            $ErrorActionPreference = 'Continue'
            # Throw $_
        }
        Finally {
            return
        }
    }        
}    

###############################################################################
# MAIN PROCESSING
###############################################################################
foreach ($table in $Tables) {
    $table = $table.ToUpper()
    
    # If the table is not defined print warning and return
    if ($ht.Get_Item($table) -eq $null) {
        Write-Warning "Table $table is not defined in the metadata.  Skipping..."
    } else {
        RunPostProcess($table)
    }
}

### END OF FILE ###
