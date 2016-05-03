#
# Script.ps1
#
#
# Script.ps1
#
        #requires -version 3.0

        <#
        .Synopsis
        Re-import VM from XML config using existing drive locations.
        .Description
        This script will read the XML configuration file from a Hyper-V backup or saved
        virtual machine configuration file and recreate the virtual machine in place 
        using the existing VHD or VHDX files. It is assumed that everything remains in
        place but that the virtual machine was removed from inventory and you want to
        restore it in place, without resorting to restoring from a backup.
        .Parameter Path
        The path to the XML Hyper-V configuration file.
        .Parameter vmPath
        The alternate location for the virtual machine.
        .Example
        PS C:\> dir e:\backup\*.xml | c:\scripts\import-VMConfig.ps1
        .Link
        New-VM
        Set-VM
        Add-VMHardDiskDrive
        Set-VMDvdDrive
        Get-Content
        .Notes
        Last Updated: March 12, 2013
        Author      : Jeffery Hicks (@JeffHicks)
        version     : 1.0

          ****************************************************************
          * DO NOT USE IN A PRODUCTION ENVIRONMENT UNTIL YOU HAVE TESTED *
          * THOROUGHLY IN A LAB ENVIRONMENT. USE AT YOUR OWN RISK.  IF   *
          * YOU DO NOT UNDERSTAND WHAT THIS SCRIPT DOES OR HOW IT WORKS, *
          * DO NOT USE IT OUTSIDE OF A SECURE, TEST SETTING.             *
          ****************************************************************
        #>

        #[cmdletbinding(SupportsShouldProcess)]
		 
function VM-importFromExistingXML(){
        Param(
        [Parameter(Position=0,Mandatory=$True,HelpMessage="Enter the path to the XML configuration file",
        ValueFromPipeline,ValueFromPipelineByPropertyname)]
        [ValidateScript({Test-Path $_})]
        [alias("fullname")]
        [string]$Path,
        [ValidateScript({Test-Path $_})]
        [string]$vmPath
        )

        Process {
        Write-Verbose "Creating VM from $Path"

        [xml]$vmconfig = Get-Content -Path $Path

        $name = $vmconfig.configuration.properties.name.'#text'

        Write-Host "Importing virtual machine $name from $path" -ForegroundColor Yellow
        $processors = $vmconfig.configuration.settings.processors.count.'#text'
        $memory = (Select-Xml -xml $vmconfig -XPath "//memory").node.Bank
        if ($memory.dynamic_memory_enabled."#text" -eq "True") {
            $dynamicmemory = $True
        }
        else {
            $dynamicmemory = $False
        }

        #memory values need to be in bytes
        $MemoryMaximumBytes = ($memory.limit."#text" -as [int]) * 1MB
        $MemoryStartupBytes = ($memory.size."#text" -as [int]) * 1MB
        $MemoryMinimumBytes = ($memory.reservation."#text" -as [int]) * 1MB

        #get the name of the virtual switch
        $switchname = (Select-Xml -xml $vmconfig -XPath "//AltSwitchName").node."#text"

        #determine boot device
        Switch ((Select-Xml -xml $vmconfig -XPath "//boot").node.device0."#text") {
        "Floppy"    { $bootdevice = "floppy" }
        "HardDrive" { $bootdevice = "IDE" }
        "Optical"   { $bootdevice = "CD" }
        "Network"   { $bootdevice = "LegacyNetworkAdapter" }
        "Default"   { $bootdevice = "IDE" }
        } #switch

        #define a hash table of parameter values for New-VM
        $newVMParams = @{
         Name = $name
         NoVHD = $True
         MemoryStartupBytes = $MemoryStartupBytes
         SwitchName = $switchname
         BootDevice = $bootdevice
         ErrorAction = "Stop"
        }

        #use the default path unless otherwise specified
        if ($vmPath) {
            $newVMParams.Add("Path",$vmPath)
        }

        Write-Verbose "Creating new virtual machine"
        Write-Verbose ($newVMParams | Out-String)

        Try {
            #create the VM using the "old" values
            $vm = New-VM @newVMParams 
        }
        Catch {
            Write-Warning "Failed to recreate virtual machine $name"
            Write-Warning $_.Exception.Message
            #bail out
            Return
        }

        $notes = (Select-Xml -xml $vmconfig -XPath "//notes").node.'#text'

        #Set-VM parameters to configure new VM with old values
        $SetVMParams = @{
            ProcessorCount = $processors
            MemoryStartupBytes = $MemoryStartupBytes
        }

        If ($dynamicmemory) {
            $SetVMParams.Add("DynamicMemory",$True)
            $SetVMParams.Add("MemoryMinimumBytes",$MemoryMinimumBytes)
            $SetVMParams.Add("MemoryMaximumBytes", $MemoryMaximumBytes)
    
        }
        else {
            $setVMParams.Add("StaticMemory",$True)
        }

        if ($notes) {
         $SetVMParams.Add("Notes",$notes)
        }

        Write-Verbose "Setting VM values"
        Write-Verbose ( $SetVMParams | out-string)
        #set the values on the VM
        $vm | Set-VM @SetVMParams -Passthru

        <#
        These items are not found in the xml file and
        may have to be manually configured:

        SmartPagingFilePath 
        AutomaticStartAction
        AutomaticStopAction
        AutomaticStartDelay
        SnapshotFileLocation
        AllowUnverifiedPaths
        #>

        #Add drives to the virtual machine
        $controllers = Select-Xml -xml $vmconfig -xpath "//*[starts-with(name(.),'controller')]"
        #a regular expression pattern to pull the number from controllers
        [regex]$rx="\d"

        foreach ($controller in $controllers) {
          $node = $controller.Node
          Write-Verbose "Processing $($node.Name)"
          #Check for SCSI 
          if ($node.ParentNode.ChannelInstanceGuid) {
             $ControllerType = "SCSI"
          }
          else {
             $ControllerType = "IDE"
          }
  
          $drives = $node.ChildNodes | where {$_.pathname."#text"}
          if (-Not $drives) {
            Write-Verbose "No configured drives found"
          }

          foreach ($drive in $drives) {   
              #if drive type is ISO then set DVD Drive accordingly
              $driveType=$drive.type."#text"
              $VHDPath = $drive.pathname."#text"
              Write-Verbose $VHDPath
              $addDriveParam = @{
                ControllerNumber = $rx.Match($controller.node.name).value
                Path = $VHDPath
              }  
                if ($drive.pool_id."#text") {
                  $ResourcePoolName = $drive.pool_id."#text"
                  $addDriveParam.Add("ResourcePoolname",$ResourcePoolName)
                }
               
                if ($drivetype -eq 'ISO') {
                    Write-Verbose "Setting DVD drive"
                    Write-Verbose ($AddDriveParam | out-string)
                    #Set-VMDvdDrive doesn't support Whatif so I have to add it
                    if ($Pscmdlet.ShouldProcess($VHDPath)) {
                        Set-VMDvdDrive -vmname $vm.name @addDriveParam
                    }
                }
                else {
                    $addDriveParam.add("ControllerType",$ControllerType)
                    Write-Verbose "Adding hard disk drive"
                    Write-Verbose ($AddDriveParam | out-string)
                    $vm | Add-VMHardDiskDrive @AddDriveparam
                }
          } #foreach drive

        } #foreach controller

        Write-Verbose "Finished processing controllers"

        } #process

        #end of script
        }