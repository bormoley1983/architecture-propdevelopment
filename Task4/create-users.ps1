[CmdletBinding()]
param(
    [string]$CredentialDirectory = (Join-Path $HOME '.kube\propdev-task4-users')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or later is required.'
}

$kubectl = Get-Command kubectl -ErrorAction Stop
$currentContext = (& $kubectl.Source config current-context).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the current kubectl context.'
}
if ($currentContext -ne 'minikube') {
    throw "Refusing to create users: current context is '$currentContext', not 'minikube'."
}

$clusterConfigJson = & $kubectl.Source config view --raw --minify --flatten -o json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the active Minikube cluster configuration.'
}
$clusterConfig = $clusterConfigJson | ConvertFrom-Json
$activeContext = $clusterConfig.contexts | Where-Object { $_.name -eq $clusterConfig.'current-context' }
if (-not $activeContext) {
    throw 'The active context is missing from the Minikube kubeconfig.'
}
$clusterName = $activeContext.context.cluster
$clusterEntry = $clusterConfig.clusters | Where-Object { $_.name -eq $clusterName }
if (-not $clusterEntry.cluster.'certificate-authority-data') {
    throw 'The Minikube CA certificate is missing from the flattened kubeconfig.'
}

New-Item -ItemType Directory -Path $CredentialDirectory -Force | Out-Null
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$icacls = Get-Command icacls.exe -ErrorAction Stop
& $icacls.Source $CredentialDirectory /inheritance:r /grant:r "$($identity):(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not restrict permissions on '$CredentialDirectory'."
}

$users = @(
    [pscustomobject]@{ Name = 'bi-analyst-01'; Group = 'propdev-cluster-viewers'; Namespace = 'propdev-data' }
    [pscustomobject]@{ Name = 'devops-operator-01'; Group = 'propdev-app-configurators'; Namespace = 'propdev-sales' }
    [pscustomobject]@{ Name = 'finance-operator-01'; Group = 'propdev-finance-configurators'; Namespace = 'propdev-finance' }
    [pscustomobject]@{ Name = 'security-officer-01'; Group = 'propdev-security-operators'; Namespace = 'propdev-smart-home' }
)

function ConvertTo-Pem {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    $encoded = [Convert]::ToBase64String($Bytes)
    $lines = [System.Text.RegularExpressions.Regex]::Matches($encoded, '.{1,64}') |
        ForEach-Object { $_.Value }
    return "-----BEGIN $Label-----`n$($lines -join "`n")`n-----END $Label-----`n"
}

foreach ($user in $users) {
    $csrName = "propdev-$($user.Name)-client"
    $keyPath = Join-Path $CredentialDirectory "$($user.Name).key.pem"
    $csrPath = Join-Path $CredentialDirectory "$($user.Name).csr.pem"
    $certPath = Join-Path $CredentialDirectory "$($user.Name).crt.pem"
    $configPath = Join-Path $CredentialDirectory "$($user.Name).kubeconfig"
    $manifestPath = Join-Path $CredentialDirectory "$csrName.yaml"

    foreach ($path in @($keyPath, $csrPath, $certPath, $configPath, $manifestPath)) {
        if (Test-Path -LiteralPath $path) {
            throw "Refusing to overwrite existing credential file '$path'. Review and rotate credentials explicitly."
        }
    }

    $existingCsr = & $kubectl.Source get csr $csrName --ignore-not-found -o name
    if ($LASTEXITCODE -ne 0) {
        throw "Could not check whether CSR '$csrName' already exists."
    }
    if ($existingCsr) {
        throw "CSR '$csrName' already exists. Review it before retrying or rotating this user's certificate."
    }

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $subject = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new(
            "CN=$($user.Name), O=$($user.Group)"
        )
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $subject,
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($keyUsage, $false)
        )
        $ekuOids = [System.Security.Cryptography.OidCollection]::new()
        $null = $ekuOids.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.2'))
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuOids, $false)
        )

        $csrBytes = $request.CreateSigningRequest()
        $privateKeyBytes = $rsa.ExportPkcs8PrivateKey()
    }
    finally {
        $rsa.Dispose()
    }

    [System.IO.File]::WriteAllText(
        $keyPath,
        (ConvertTo-Pem -Label 'PRIVATE KEY' -Bytes $privateKeyBytes),
        [System.Text.Encoding]::ASCII
    )
    [System.IO.File]::WriteAllText(
        $csrPath,
        (ConvertTo-Pem -Label 'CERTIFICATE REQUEST' -Bytes $csrBytes),
        [System.Text.Encoding]::ASCII
    )

    $requestBase64 = [Convert]::ToBase64String($csrBytes)
    $csrManifest = @"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $csrName
spec:
  request: $requestBase64
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - digital signature
    - key encipherment
    - client auth
"@
    [System.IO.File]::WriteAllText($manifestPath, $csrManifest, [System.Text.UTF8Encoding]::new($false))

    & $kubectl.Source apply -f $manifestPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not submit CSR '$csrName'."
    }
    & $kubectl.Source certificate approve $csrName
    if ($LASTEXITCODE -ne 0) {
        throw "Could not approve CSR '$csrName'."
    }

    $certificateBase64 = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $certificateBase64 = (& $kubectl.Source get csr $csrName -o jsonpath='{.status.certificate}').Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not retrieve the issued certificate for '$csrName'."
        }
        if ($certificateBase64) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $certificateBase64) {
        throw "The signer did not issue a certificate for '$csrName' within 30 seconds."
    }
    $certificateBytes = [Convert]::FromBase64String($certificateBase64)
    [System.IO.File]::WriteAllBytes($certPath, $certificateBytes)

    $userConfig = [ordered]@{
        apiVersion = 'v1'
        kind = 'Config'
        clusters = @(
            [ordered]@{
                name = $clusterName
                cluster = [ordered]@{
                    server = $clusterEntry.cluster.server
                    'certificate-authority-data' = $clusterEntry.cluster.'certificate-authority-data'
                }
            }
        )
        users = @(
            [ordered]@{
                name = $user.Name
                user = [ordered]@{
                    'client-certificate-data' = [Convert]::ToBase64String($certificateBytes)
                    'client-key-data' = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keyPath))
                }
            }
        )
        contexts = @(
            [ordered]@{
                name = "propdev-$($user.Name)"
                context = [ordered]@{
                    cluster = $clusterName
                    user = $user.Name
                    namespace = $user.Namespace
                }
            }
        )
        'current-context' = "propdev-$($user.Name)"
    }
    [System.IO.File]::WriteAllText(
        $configPath,
        ($userConfig | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Output "Created $($user.Name) in group $($user.Group); kubeconfig: $configPath"
}
