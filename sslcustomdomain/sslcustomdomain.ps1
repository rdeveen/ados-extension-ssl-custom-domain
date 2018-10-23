param (
    [string] $ResourceGroupName,
    [string] $AppServiceName,
    [string] $CustomDomains,
    [string] $CertificatePassword,
    [string] $CertificateFileName
)

Write-Host $ResourceGroupName
Write-Host $AppServiceName
Write-Host $CustomDomains
Write-Host $CertificatePassword
Write-Host $CertificateFileName

# $ResourceGroupName = Get-VstsInput -Name "ResourceGroupName"
$ResourceWebsiteName = $AppServiceName
# $CustomDomains = (Get-VstsInput -Name "CustomDomains").Split(",")
# $CertificatePassword = Get-VstsInput -Name "CertificatePassword"
$CertificateFilePath = $env:AGENT_TEMPDIRECTORY + "/" +  $CertificateFileName

Write-Host $CertificateFilePath

$WebAppResource = Get-AzureRmResource -Name $ResourceWebsiteName -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites -ApiVersion 2014-11-01

$certificateObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$certificateObject.Import($CertificateFilePath, $CertificatePassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
$CertificateThumbprint  =$certificateObject.Thumbprint

$UploadedCertificateResource = Get-AzureRmResource -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/certificates -ApiVersion 2018-09-01 | Where-Object { $_.Properties.Thumbprint -eq $CertificateThumbprint } 
if ($UploadedCertificateResource -eq $null)
{   
    Write-Host ("Certificate does not exist. Uploading with thumbprint {0} ..." -f $CertificateThumbprint)

    $pfxContents = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($CertificateFilePath))

    $CertificateProperties = @{"pfxBlob" = $pfxContents; "password" = $CertificatePassword}
    $UploadedCertificateResource = New-AzureRmResource -Name $CertificateThumbprint -Location $WebAppResource.Location -PropertyObject $CertificateProperties -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/certificates -ApiVersion 2015-08-01 -Force
}

foreach ($CustomDomain in $CustomDomains) 
{
    $HostnameBinding = $WebAppResource.Properties.HostNames | Where-Object { $_ -eq $CustomDomain }
    if ($HostnameBinding -eq $null) 
    {
        $HostnameBindingProperties = @{
            SiteName = $ResourceWebsiteName;
            HostNameType = "Verified";
        }
        
        Write-Host ("Hostname binding for {0} does not exist. Creating ..." -f $CustomDomain)
         
        New-AzureRmResource -ResourceName "$ResourceWebsiteName/$CustomDomain" -Location $WebAppResource.Location -PropertyObject $HostnameBindingProperties -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites/hostNameBindings -ApiVersion 2015-08-01 -Force | Out-Null
        
        $WebAppResource = Get-AzureRmResource -Name $ResourceWebsiteName -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites -ApiVersion 2014-11-01
    }
    
    $WebProperties = $WebAppResource.Properties
    [System.Collections.ArrayList]$HostnameSslStates = $WebProperties.HostNameSslStates
    
    $SslState = $WebProperties.HostNameSslStates | Where-Object { $_.name -eq $CustomDomain }
    if ($SslState -eq $null -or $SslState.Thumbprint -eq $null) 
    {
        $SslState = @{
            name = $CustomDomain
            SslState = 1
            thumbprint = $CertificateThumbprint
            toUpdate = $true
        }

        $HostnameSslStates.Add($SslState)
        $WebProperties.HostNameSslStates = $HostnameSslStates
        try
        {
            Write-Host ("Hostname SSL binding for {0} does not exist. Creating binding with thumbprint {1} ..." -f $CustomDomain, $CertificateThumbprint)
            
            Set-AzureRmResource -Name $ResourceWebsiteName -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites -PropertyObject $WebProperties -ApiVersion 2014-11-01 -Force | Out-Null
        }
        catch 
        {
            Write-Host ("Cannot set hostname SSL binding for {0}." -f $CustomDomain)
            throw
        }
    }
    else 
    {
        if ($SslState.Thumbprint -notmatch $CertificateThumbprint) 
        {
            Write-Host ("Hostname SSL binding for {0} does exist, but the thumbprint does not match. Override old SSL binding with thumbprint {1} -> {2} ..." -f $CustomDomain, $SslState.Thumbprint, $CertificateThumbprint)
            
            $SslState.SslState = 1
            $SslState.thumbprint = $CertificateThumbprint
            $SslState.toUpdate = $true
    
            $WebProperties.HostNameSslStates[$HostnameSslStates.IndexOf($SslState)] = $SslState
        
            Set-AzureRmResource -Name $ResourceWebsiteName -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites -PropertyObject $WebProperties -ApiVersion 2014-11-01 -Force | Out-Null
        }
    }
}