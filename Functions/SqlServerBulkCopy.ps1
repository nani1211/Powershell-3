Function SqlServerBulkCopy
{
<# 
Header goes here...
#>
    [CmdletBinding( DefaultParameterSetName = 'Instance',
                    SupportsShouldProcess = $true,
                    ConfirmImpact = 'Medium' )]
    param(
        # Source
        [ValidateNotNullOrEmpty()]
        [Alias('ss','srcsvr')]
        [String]
        $SrcServer              = 'DOHNSCLDBSASBI,54491'
        ,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('sdb','srcdb')]
        [String]
        $SrcDatabase
        ,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ssc','srcsch')]
        [String]
        $SrcSchema              = 'dbo'
        ,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('stb','srctbl')]
        [String]
        $SrcTable
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
        $TgtDatabase            = $SrcDatabase
        ,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('tsc','tgtsch')]
        [String]
        $TgtSchema              = $SrcSchema
        ,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('ttb','tgttbl')]
        [String]
        $TgtTable               = $SrcTable
        ,

        # Script options
        [Alias('sql','query')]
        [ValidateNotNullOrEmpty()]
        [String]
        $SqlQuery               = "SELECT * FROM $SrcTable"
        ,
        [switch]
        $Clone
        ,
        [switch]
        $Rename
        ,
        [switch]
        $Truncate
        ,
        [switch]
        $Quiet
        ,
        [Alias('timeout')]
        [int]
        $CommandTimeout         = 120 # mainly used when retrieving initial row count
                                      # set to a smaller value if you do not want to wait as long
        ,

        # SqlBulkCopy constructor options
        # See https://msdn.microsoft.com/en-us/library/system.data.sqlclient.sqlbulkcopyoptions(v=vs.110).aspx
        [switch]
        $CheckConstraints       = $true
        ,
        [switch]
        $FireTriggers           = $false
        ,
        [switch]
        $KeepIdentity           = $true
        ,
        [switch]
        $KeepNulls              = $true
        ,
        [switch]
        $TableLock              = $true
        ,

        # SqlBulkCopy runtime properties
        # See https://msdn.microsoft.com/en-us/library/system.data.sqlclient.sqlbulkcopy(v=vs.110).aspx
        [int]
        $BatchSize              = 0         # all data written in one transaction
        ,
        [int]
        $BulkCopyTimeout        = 14440     # 4 hours
        ,
        [int]
        $NotifyAfter            = 1000000   # progress report every 1M records processed
                                            # 0 = no progress reports, including the progress bar
                                            # -verbose must be specified for the console output
    )

    ###############################################################################
    # Functions
    ###############################################################################
    Function ConnectionString([string] $ServerName, [string] $DbName)
    {
        "Data Source=$ServerName;Initial Catalog=$DbName;Integrated Security=True;Connection Timeout=120"
    }

    Function Print-Parms
    {
        if ($quiet) {return}
        if (! $verbose) {return}

        # list the parameters
        $name= @{Label='Parameter';  Expression={$_.Name};  Width=30}
        $value=@{Label='Value';      Expression={$_.Value}; Width=200}

        Push-Location variable:
        Get-Item `
            SrcServer,SrcDatabase,SrcTable,`
            TgtServer,TgtDatabase,TgtTable,`
            Clone,Rename,Truncate,Quiet,CommandTimeout,`
            CheckConstraints,FireTriggers,KeepIdentity,KeepNulls,TableLock,`
            BatchSize,BulkCopyTimeout,NotifyAfter, `
            SqlQuery | `
            Format-Table $name,$value -Wrap | Out-Host
        Pop-Location
    }

    # Helper function: we are only on Powershell V2.0
    Function StringIsNullOrWhitespace([string] $string)
    {
        if ($string -ne $null) { $string = $string.Trim() }
        return [string]::IsNullOrEmpty($string)
    }

    ###############################################################################
    # Initialization
    ###############################################################################
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop'

    # Error check: target table cannot be the same as the source table
    $msg_src=$SrcServer,($SrcDatabase,$SrcSchema,$SrcTable -join '.') -join ':';
    $msg_tgt=$TgtServer,($TgtDatabase,$TgtSchema,$TgtTable -join '.') -join ':';
    if ($msg_tgt.trim() -eq $msg_src.trim()) {
        Throw "Target $msg_tgt cannot be the same as Source $msg_src"
    }
   
    # Define SQL commands used in this script
   
    # 0=$SqlQuery
    $SqlRowCount = @'
SELECT COUNT(1) FROM ({0}) AS [ROW_COUNT]
'@

    # 0=$TgtServer, 1=$TgtDatabase, 2=$TgtSchema, 3=$TgtTable
    $SqlDropTable = @'
IF OBJECT_ID(N'[{1}].[{2}].[{3}]') IS NOT NULL DROP TABLE [{1}].[{2}].[{3}]
'@   

    # 0=$TgtServer, 1=$TgtDatabase, 2=$TgtSchema, 3=zzz_$TgtTable, 4=$SqlQuery
    $SqlCloneTable = @'
SELECT * INTO [{1}].[{2}].[{3}] FROM ({4}) AS X WHERE 0=1;
'@

    # 0=$TgtServer, 1=$TgtDatabase, 2=$TgtSchema, 3=$TgtTable (either original or "zzz")
    $SqlTruncateTable = @'
IF OBJECT_ID(N'[{1}].[{2}].[{3}]') IS NOT NULL TRUNCATE TABLE [{1}].[{2}].[{3}]
'@
   
    # 0=$TgtServer, 1=$TgtDatabase, 2=$TgtSchema, 3=$TgtTable (should be "zzz"), 4=original $TgtTable
    $SqlRenameTable = @'
IF OBJECT_ID(N'[{1}].[{2}].[{3}]') IS NOT NULL exec sp_rename '[{1}].[{2}].[{3}]', '{4}'
'@
   
    # Startup message
    if (! $quiet) {
        $msg = @'
[*] Script:    Started at {0}
'@ -f $(Get-Date)
        Write-Host ($msg) -BackgroundColor Cyan -ForegroundColor Black
    }

    # Begin stopwatch
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()

    # Resolve any embedded variables in $SqlQuery
    # Usually SELECT * FROM $SrcTable
    $SqlQuery = Invoke-Expression "Write-Output `"$SqlQuery`""

    # Get verbose status
    $verbose = $VerbosePreference -ne 'SilentlyContinue'

    # Print parameters
    Print-Parms

    # Connection strings
    $SrcConnStr = ConnectionString $SrcServer $SrcDatabase
    $TgtConnStr = ConnectionString $TgtServer $TgtDatabase

    # Create source objects
    $SrcConn = New-Object System.Data.SqlClient.SQLConnection
    $SrcCmd  = New-Object System.Data.SqlClient.SqlCommand

    $SrcConn.ConnectionString = $SrcConnStr
    $SrcCmd.Connection = $SrcConn
    $SrcConn.Open()

    ###############################################################################
    # Get Initial Row Count
    ###############################################################################
    if (! $quiet) {
        $msg = @'
[*] Row Count: Table {0}: Getting row count from query
'@ -f $msg_src
        Write-Host ($msg)
    }

    Try {
        $temp = $SqlQuery -replace "\[${SrcServer}*\]\.",''
        $SqlCommandText = $SqlRowCount -f $temp
        $SrcCmd.CommandText = $SqlCommandText
        $SrcCmd.CommandTimeout = $CommandTimeout
        $SrcRowCount = $SrcCmd.ExecuteScalar()
    }
    Catch [System.Data.SqlClient.SqlException]
    {
        $ex = $_.Exception
        if ($ex.Number -eq -2) {
            $msg = @'
[*] Row Count: Table {0}: Timeout getting initial row count after {1:N0} seconds. Continuing without initial row count.
'@ -f $msg_src, $CommandTimeout
            Write-Host ($msg) -BackgroundColor Yellow -ForegroundColor Black
            $SrcRowCount='???'
        } else {
            Throw $ex
        }
    }
    Catch [System.Exception]
    {
        $ex = $_.Exception
        Throw $ex
    }

    if (! $quiet) {
        $timetaken = $elapsed.Elapsed.TotalSeconds
        $msg = @'
[*] Row Count: Table {0}: {1:N0} rows retrieved in {2:N2} seconds
'@ -f $msg_src, $SrcRowCount, $timetaken
        Write-Host ($msg)
    }

    ###############################################################################
    # ShouldProcess()
    ###############################################################################
    if ($PSCmdlet.ShouldProcess(
        ('Copy {0:N0} rows from {1} to {2}' -f $SrcRowCount, $msg_src, $msg_tgt), 'SQL Bulk Copy'
    ))
    {
        Try {
            # Create target objects
            $TgtConn = New-Object System.Data.SqlClient.SQLConnection
            $TgtCmd  = New-Object System.Data.SqlClient.SqlCommand

            $TgtConn.ConnectionString = $TgtConnStr
            $TgtCmd.Connection = $TgtConn
            $TgtConn.Open()

            ###############################################################################
            # Clone
            ###############################################################################
            if ($clone) {
                # Save value of $TgtTable 
                $TgtTableOrig = $TgtTable
                $TgtTable     = "zzz_$TgtTable"

                $msg_stg      = $TgtServer,($TgtDatabase,$TgtSchema,$TgtTable -join '.') -join ':'

                if (! $quiet) {
                    $msg = @'
[*] Clone:     Table {0} to {1}
'@ -f $msg_tgt, $msg_stg
                    Write-Host ($msg)
                }
            
                # Drop table (use Tgt objects)
                $SqlCommandText = $SqlDropTable -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTable
                $TgtCmd.CommandText = $SqlCommandText 
                [Void]$TgtCmd.ExecuteNonQuery()

                # Clone table (use Tgt objects)
                $SqlCommandText = $SqlCloneTable -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTable, $SqlQuery
                $TgtCmd.CommandText = $SqlCommandText
                [Void]$TgtCmd.ExecuteScalar()
            
                if (! $quiet) {
                    $timetaken = $elapsed.Elapsed.TotalSeconds
                    $msg = @'
[*] Clone:     Table {0} to {1} in {2:N2} seconds
'@ -f $msg_tgt, $msg_stg, $timetaken
                    Write-Host ($msg)
                }
            }

            ###############################################################################
            # Truncate
            ###############################################################################
            if ($truncate) {
                if (! $quiet) {
                    $msg = @'
[*] Truncate:  Table {0}
'@ -f ($TgtServer,($TgtDatabase,$TgtSchema,$TgtTable -join '.') -join ':')
                    Write-Host ($msg)
                }

                $SqlCommandText = $SqlTruncateTable -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTable
                $TgtCmd.CommandText = $SqlCommandText
                [Void]$TgtCmd.ExecuteNonQuery()
           
                if (! $quiet) {
                    $timetaken = $elapsed.Elapsed.TotalSeconds
                    $msg = @'
[*] Truncate:  Table {0} truncated in {1:N2} seconds
'@ -f ($TgtServer,($TgtDatabase,$TgtSchema,$TgtTable -join '.') -join ':'), $timetaken
                    Write-Host ($msg)
                }
            }

            ###############################################################################
            # Load Target Table
            ###############################################################################
            if (! $quiet) {
                $msg = @'
[*] Load:      Table {0}
'@ -f ($TgtServer,($TgtDatabase,$TgtSchema,$TgtTable -join '.') -join ':')
                Write-Host ($msg)
            }

            $SqlCommandText = $SqlQuery
            $TgtCmd.CommandText = $SqlCommandText
            $TgtCmd.CommandTimeout = $BulkCopyTimeout # give enough time for the DataReader to load, AP_Identified is very slow!
            [System.Data.SqlClient.SqlDataReader] $SqlReader = $TgtCmd.ExecuteReader()

            # Create constructor options
            # (There is probably a more elegant way to do this!)
            $BulkCopyOptions=@() # empty array
            if ($CheckConstraints) {$BulkCopyOptions += 'CheckConstraints'}
            if ($FireTriggers    ) {$BulkCopyOptions += 'FireTriggers'    }
            if ($KeepIdentity    ) {$BulkCopyOptions += 'KeepIdentity'    }
            if ($KeepNulls       ) {$BulkCopyOptions += 'KeepNulls'       }
            if ($TableLock       ) {$BulkCopyOptions += 'TableLock'       }
            $BulkCopyOptions=$BulkCopyOptions -join ','
            if (StringIsNullOrWhiteSpace($BulkCopyOptions)) {$BulkCopyOptions = 'Default'}

            $BulkCopy = New-Object Data.SqlClient.SqlBulkCopy($TgtConn.ConnectionString, $BulkCopyOptions)
            $BulkCopy.DestinationTableName=($TgtSchema,$TgtTable -join '.')
            $BulkCopy.BulkcopyTimeout=$BulkCopyTimeout
            $BulkCopy.Batchsize=$BatchSize
            $BulkCopy.NotifyAfter=$NotifyAfter

            # Add rowcount output
            $BulkCopy.Add_SqlRowscopied({
                if (! $quiet) {
                    $TotalRows = $args[1].RowsCopied
                    $timetaken = $elapsed.Elapsed.TotalSeconds
                    if ($SrcRowCount -is [int]) {
                        $percent = [int](($TotalRows/$SrcRowCount)*100)
                        $msg = @'
Progress: {0,12:N0} of {1,12:N0} rows ({2,3:N0}%) in {3,9:N2} seconds
'@ -f $TotalRows, $SrcRowCount, $percent, $timetaken
                        Write-Verbose ($msg)
                        Write-Progress `
                            -id 1 `
                            -activity ('Inserting {0,12:N0} rows' -f $SrcRowCount) `
                            -status ('Progress: {0,12:N0} of {1,12:N0} rows ({2,3:N0}%) in {3,9:N2} seconds' -f $TotalRows, $SrcRowCount, $percent, $timetaken) `
                            -percentcomplete $percent
                    } else {
                        $msg = @'
Progress: {0,12:N0} of {1,12:N0} rows ({2}%) in {3,9:N2} seconds
'@ -f $TotalRows, $SrcRowCount, '??', $timetaken
                        Write-Verbose ($msg)
                    }
                }
            })

            $BulkCopy.WriteToServer($SqlReader)
            $SqlReader.Close()
            
            # Write final message
            if (! $quiet) {
                $TotalRows = $SrcRowCount
                $timetaken = $elapsed.Elapsed.TotalSeconds
                if ($SrcRowCount -is [int]) {
                    $percent = [int](($TotalRows/$SrcRowCount)*100)
                    $msg = @'
Progress: {0,12:N0} of {1,12:N0} rows ({2,3:N0}%) in {3,9:N2} seconds
'@ -f $TotalRows, $SrcRowCount, $percent, $timetaken
                    Write-Verbose ($msg)
                    Write-Progress `
                        -id 1 `
                        -activity ('Inserting {0,12:N0} rows' -f $SrcRowCount) `
                        -status ('Progress: {0,12:N0} of {1,12:N0} rows ({2,3:N0}%) in {3,9:N2} seconds' -f $TotalRows, $SrcRowCount, $percent, $timetaken) `
                        -percentcomplete $percent `
                        -completed
                } else {
                    $msg = @'
Progress: {0,12:N0} of {1,12:N0} rows ({2}%) in {3,9:N2} seconds
'@ -f $TotalRows, $SrcRowCount, '100', $timetaken
                    Write-Verbose ($msg)
                }
            }
                
            ###############################################################################
            # Rename
            ###############################################################################
            if ($Clone -and $Rename) {
                if (! $quiet) {
                    $msg = @'
[*] Rename:    Table {0} to {1}
'@ -f $msg_stg, $msg_tgt
                    Write-Host ($msg)
                }

                # Drop original table
                $SqlCommandText = $SqlDropTable -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTableOrig
                $TgtCmd.CommandText = $SqlCommandText
                [Void]$TgtCmd.ExecuteNonQuery()
           
                # Rename cloned table to original table
                $SqlCommandText = $SqlRenameTable -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTable, $TgtTableOrig
                $TgtCmd.CommandText = $SqlCommandText
                [Void]$TgtCmd.ExecuteNonQuery()
           
                if (! $quiet) {
                    $timetaken = $elapsed.Elapsed.TotalSeconds
                    $msg = @'
[*] Rename:    Table {0} to {1} in {2:N2} seconds
'@ -f $msg_stg, $msg_tgt, $timetaken
                    Write-Host ($msg)
                }

                # switch $TgtTable back to original value
                $TgtTable = $TgtTableOrig
            }
         
            ###############################################################################
            # Get Final Row Count
            ###############################################################################
            Try {
                $SqlCommandText = $SqlRowCount -f ('SELECT * FROM [{1}].[{2}].[{3}]' -f $TgtServer, $TgtDatabase, $TgtSchema, $TgtTable)
                $TgtCmd.CommandText = $SqlCommandText
                $CommandTimeout = 300 # 5 minutes
                $TgtCmd.CommandTimeout = $CommandTimeout
                $TgtRowCount = $TgtCmd.ExecuteScalar()
            }
            Catch [System.Data.SqlClient.SqlException]
            {
                $ex = $_.Exception
                if ($ex.Number -eq -2) {
                    $msg = @'
[*] Row Count: Table {0}: Timeout getting final row count after {1:N} seconds.
'@ -f $msg_tgt, $CommandTimeout
                    Write-Host ($msg) -BackgroundColor Yellow -ForegroundColor Black
                    $TgtRowCount='???'
                } else {
                    Throw $ex
                }
            }
            Catch [System.Exception]
            {
                $ex = $_.Exception
                Throw $ex
            }
            
            $timetaken = $elapsed.Elapsed.TotalSeconds
            $msg = @'
[*] Load:      Table {0}: {1:N0} rows copied in {2:N2} seconds
'@ -f $msg_tgt, $TgtRowCount, $timetaken         
            Write-Host ($msg)
        }
        Catch [System.Data.SqlClient.SqlException]
        {
            # No custom error trapping for now
            $ex = $_.Exception
            Throw $ex
            <#         
            if ($ex.Message.Contains('Received an invalid column length from the bcp client for colid'))
            {
                # get the column number
                $pattern = '\d+'
                $match = $ex.Message.ToString() -match $pattern
                $index = [int]$matches[0]

                $fi = $BulkCopy.get_ColumnMappings
                $sortedColumns = $fi.Value
                $items = [Object[]] $sortedColumns.GetType().GetField('_items').GetValue($sortedColumns)

                $itemdata = $items[$index].GetType().GetField('_metadata')
                $metadata = $itemdata.GetValue($items[$index])

                $column = $metadata.GetType().GetField('column').GetValue($metadata)
                $length = $metadata.GetType().GetField('length').GetValue($metadata)
                throw new DataFormatException('Column: {0} contains data with a length greater than: {1}' -f $column, $length)
            }
            throw
            #>
        }
        Catch [System.Exception]
        {
            $msg = @'
[*] Load:      Table {0}: Error loading table
'@ -f $msg_tgt
            Write-Host ($msg) -BackgroundColor Red -ForegroundColor Black

            $ex = $_.Exception
            Throw $ex
        }
    }
   
    ###############################################################################
    # Termination/Cleanup
    ###############################################################################
    Try {
        if (Test-Path variable:TgtConn)     {$TgtConn.Close();$TgtConn.Dispose()}
        if (Test-Path variable:TgtCmd)      {$TgtCmd.Dispose()}
        if (Test-Path variable:SqlReader)   {$SqlReader.Close();$SqlReader.Dispose()}
        if (Test-Path variable:BulkCopy)    {$BulkCopy.Close()}

        if (Test-Path variable:SrcConn)     {$SrcConn.Close();$SrcConn.Dispose()}
        if (Test-Path variable:SrcCmd)      {$SrcCmd.Dispose()}
    }
    Catch {
    }
    Finally {
        [System.GC]::Collect()
        if (! $quiet) {
            $msg = @'
[*] Script:    Ended   at {0}
'@ -f $(Get-Date)
            Write-Host ($msg) -BackgroundColor Green -ForegroundColor Black
        }
    }
}

### END OF FILE ###
