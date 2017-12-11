﻿#####
# IMPORTANT: !!!!! Ensure the password is set outside of this script to prevent a secret from being checked into the repo accidentally !!!!!
#
# ===== Instructions =====
# 1. In the console, set the variable $global:SP_PASSWD to the value of the blockchain dev service principle password.  This is saved in the 
#    "BlockchainTeamSecrets" KeyVault under Blockchain Non-Prod subscription secret named "blockchain-service-principle-devs"
# 2. This function runAllDeployments() in this module can be run in two modes: "D" provisions resources via the deployment template  
#    and "T" tears down resources that were provisioned.  Manually validate the deployments and then tear them down.
#
# Note: In this module, various commands return value is assigned to $tmp to avoid excess logging to the console
#       Instructions to setup service principle were sourced from http://blog.davidebbo.com/2014/12/azure-service-principal.html
#####

# Constants
$SERVICE_PRINCIPAL_NAME     = "<PLACEHOLDER>";
$CLIENT_ID                  = "<PLACEHOLDER>"; # blockchain dev service principle username (password is retrieved from key vault)
$TENANT_ID                  = "<PLACEHOLDER>"; # @microsoft.com tenant
$PRE_VALIDATION_SLEEP_SEC   = 90;

# Create a credentials object that will be used to login as the service principle authorized on the subscription
if([string]::IsNullOrEmpty($global:SP_PASSWD)) {
  throw "Service Principle password is not set. Exiting";
}
$secpasswd = ConvertTo-SecureString $global:SP_PASSWD -AsPlainText -Force
$sp_creds = New-Object System.Management.Automation.PSCredential ($CLIENT_ID, $secpasswd)

$deploymentBlock = {
  $tenantID              = $args[0];
  $creds                 = $args[1];
  $subscriptionID        = $args[2];
  $resourceGroupName     = $args[3];
  $resourceGroupLocation = $args[4];
  $templateURI           = $args[5];
  $templateParams        = $args[6];
  $deploymentName        = $resourceGroupName;
  $preValidationSleepSec = $args[7];

  Try {
    # Login in this job session
    $output = Login-AzureRmAccount -ServicePrincipal -Tenant $tenantID -Credential $creds -SubscriptionId $subscriptionID 2>&1;
    $err = $output | ?{$_.gettype().Name -eq "ErrorRecord"};
    if($err) 
    { throw "Encountered Error logging in as service principal: $output"; }
    # Create resource group
    $output = New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation 2>&1;
    $err = $output | ?{$_.gettype().Name -eq "ErrorRecord"};
    if($err) 
    { throw "Encountered Error creating resource group: $output"; }
    # Params as object version
    $output = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $resourceGroupName -TemplateUri $templateURI -TemplateParameterObject $templateParams 2>&1;
    $err = $output | ?{$_.gettype().Name -eq "ErrorRecord"};
    if($err) 
    { throw "Encountered Error deploying to resource group: $output"; }

    # Wait for nodes to peer before validating deployment
    Start-Sleep -s $preValidationSleepSec;
    $deployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -deploymentName $resourceGroupName;

    # Verify that admin website is up
    $webpage = Invoke-WebRequest $deployment.Outputs['admin-site'].Value
    $isRunning = $webpage.Content | Select-String -Pattern "Not Running"
    if (![string]::IsNullOrEmpty($isRunning))
    { throw "At least one node is not running" }

    # Verify that no nodes have peercount 0
    # Peercounts are in the 2nd table, 3rd column
    $table = @($webpage.ParsedHtml.getElementsByTagName("table"))[1]
    $rows = @($table.rows)
    foreach($row in $rows) {
        $cells = @($row.Cells)
        $peercount = $cells[2].innerText
        $count=0
       while ($count -lt 10){
        if ($peercount -eq 0)
	    {
            start-sleep -seconds 90
		    $count++
        }
 
        else
        {
             break
        }
        }
        $peercount = $cells[2].innerText
        if ($peercount -eq "0")
        { throw "At least one node has peercount 0" }
    }

    # Verify that the JSON RPC endpoint is responsive
    $webpage = Invoke-WebRequest $deployment.Outputs['ethereum-rpc-endpoint'].Value
    $isRunning = $webpage.Content | Select-String -Pattern "jsonrpc"
    #$isRunning = $webpage.RawContent | Select-String -Pattern "200 OK"  added for testing
    if ([string]::IsNullOrEmpty($isRunning))
    { throw "JSON RPC not responding" }
  } 
  Catch {
    echo "Deployment Job for resource group $resourceGroupName failed with the following errors:`n";
    echo "$Error`n";
  }
}

$teardownBlock = {
  $tenantID          = $args[0];
  $creds             = $args[1];
  $subscriptionID    = $args[2];
  $resourceGroupName = $args[3];

  Try {
    # Login in this job session
    $temp = Login-AzureRmAccount -ServicePrincipal -Tenant $tenantID -Credential $creds  -SubscriptionId $subscriptionID 2>&1
    $status = Remove-AzureRmResourceGroup -ResourceGroupName $resourceGroupName -Force 2>&1;
    $err = $status | ?{$_.gettype().Name -eq "ErrorRecord"};
    if($status -and !$err) 
    { echo "Successfully tore down resource group $resourceGroupName`n"; }
    else 
    { 
      echo "Failed to tear down resource group $resourceGroupName due to:`n";
      echo "$status`n"; 
    }
  } 
  Catch {
    echo "Deployment Job for resource group $resourceGroupName failed with the following errors:`n";
    echo "$Error`n";
  }
}

function RunAllDeployments([HashTable]$ParamSet,
                           [String]$SubscriptionID,
                           [String]$ResourceGroupLocation,
                           [String]$TemplateURI,
                           [String]$ResourceGroupNamePrefix="ethnet-automated-test",
                           [String]$JobNamePrefix="TemplateDeployment",
                           [Bool]$Teardown=$TRUE)
{
  echo "Deploying into SubscriptionID: $SubscriptionID`n";

  $paramKeyToResourceGroupNameMap = @{};
  $paramKeyToJobNameMap = @{};
  $paramKeyToJobOutputMap = @{};

  # $ParamSet variable is defined in the params file that was dot sourced above
  $seqNum = 0;
  foreach ($key in $ParamSet.Keys)
  {
    $jobNum = $seqNum++;
    $jobName = $JobNamePrefix+$jobNum;
    $resourceGroupName = $ResourceGroupNamePrefix+$jobNum;
    $paramKeyToResourceGroupNameMap.Add($key, $resourceGroupName);
    $paramKeyToJobNameMap.Add($key, $jobName);

    $temp = Start-Job $deploymentBlock -Name $jobName -ArgumentList $TENANT_ID, $sp_creds, $SubscriptionID, $resourceGroupName, $ResourceGroupLocation, $TemplateURI, $ParamSet.Item($key), $PRE_VALIDATION_SLEEP_SEC;
    echo "Started deployment into resource group $resourceGroupName`n"
  }

  # Wait for jobs to finish and save output
  foreach ($key in $ParamSet.Keys)
  {
    $jobName = $paramKeyToJobNameMap.Item($key);
    echo "Waiting for job $jobName (params $key)`n"
    $jobOutput = Receive-Job -Name $jobName -Wait -Force
    $paramKeyToJobOutputMap.Add($key, $jobOutput);
    Remove-Job -Name $jobName
  }

  # Check and report on operation status of each parameter set
  $temp = Login-AzureRmAccount -ServicePrincipal -Tenant $TENANT_ID -Credential $sp_creds -SubscriptionId $SubscriptionID
  foreach ($key in $ParamSet.Keys)
  {
    # Deployment name of the main deployment is the same as the resoruce group name if none was specified
    $resourceGroupName = $paramKeyToResourceGroupNameMap.Item($key);

    Try {
      $deployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -deploymentName $resourceGroupName;
      $err = $deployment | ?{$_.gettype().Name -eq "ErrorRecord"};
      if($err) 
      { throw "Failed to get resoruce group deployment via Get-AzureRmResourceGroupDeployment for resource group $resourceGroupName`n"; } 
    }
    Catch {
      echo $Error;
    }
    if(($deployment.ProvisioningState -eq "Succeeded") -and (-not ($paramKeyToJobOutputMap.Item($key) -like "*failed*"))) 
    { 
      echo "`n";
      echo "========================================`n"
      echo "Deployment SUCCEEDED for parameter set ($key) and resource group ($resourceGroupName)`n";
      echo "Deployment outputs:`n";
      echo "========================================`n"
      foreach ($output in $deployment.Outputs) 
      {
        foreach ($key in $output.Keys) 
        { 
          $msg = "$key --> "+$deployment.Outputs[$key].Value;
          echo "$msg`n"; 
        } 
      }
      echo "========================================`n"
      if($Teardown)
      {
        $temp = Start-Job $teardownBlock -ArgumentList $TENANT_ID, $sp_creds, $SubscriptionID, $resourceGroupName;
        echo "Started teardown of resource group $resourceGroupName`n"
      }
      else
      {
        echo "Teardown of resource group $resourceGroupName skipped as requested`n"
      }
    }
    else
    { 
      echo "`n";
      echo "========================================`n"
      echo "Deployment FAILED for parameter set ($key) and resource group ($resourceGroupName)`n";
      echo "!!!DEPLOYMENT WILL BE LEFT RUNNING FOR INVESTIGATION!!!`n"
      echo "Deployment job output:`n";
      echo "========================================`n"
      $msg = $paramKeyToJobOutputMap.Item($key);
      echo "$msg`n"
      echo "========================================`n" 
    }
  } 
  Get-Job | Wait-Job
  
  echo "All operations completed`n";
}

function TeardownDeployment([String]$SubscriptionID,
                            [String]$ResourceGroupName)
{
   $jobID = Start-Job $teardownBlock -ArgumentList $TENANT_ID, $sp_creds, $SubscriptionID, $ResourceGroupName;
   echo "Started teardown of resource group $resourceGroupName`n";
   Wait-Job $jobID;
   echo "Teardown of resource group $resourceGroupName complete`n";
}