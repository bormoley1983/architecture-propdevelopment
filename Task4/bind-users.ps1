Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kubectl = Get-Command kubectl -ErrorAction Stop
$currentContext = (& $kubectl.Source config current-context).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the current kubectl context.'
}
if ($currentContext -ne 'minikube') {
    throw "Refusing to create bindings: current context is '$currentContext', not 'minikube'."
}

function Invoke-ApplyManifest {
    param([Parameter(Mandatory)][string]$Manifest)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "propdev-task4-$([guid]::NewGuid().ToString('N')).yaml"
    [System.IO.File]::WriteAllText($path, $Manifest, [System.Text.UTF8Encoding]::new($false))
    try {
        & $kubectl.Source apply -f $path
        if ($LASTEXITCODE -ne 0) {
            throw 'kubectl apply failed while creating a role binding.'
        }
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-viewers
subjects:
  - kind: Group
    name: propdev-cluster-viewers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: propdev-cluster-viewer
  apiGroup: rbac.authorization.k8s.io
'@

foreach ($namespace in @('propdev-sales', 'propdev-residents', 'propdev-data')) {
    Invoke-ApplyManifest -Manifest @"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: propdev-app-configurators
  namespace: $namespace
subjects:
  - kind: Group
    name: propdev-app-configurators
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: propdev-namespace-configurator
  apiGroup: rbac.authorization.k8s.io
"@
}

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: propdev-finance-configurators
  namespace: propdev-finance
subjects:
  - kind: Group
    name: propdev-finance-configurators
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: propdev-namespace-configurator
  apiGroup: rbac.authorization.k8s.io
'@

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: propdev-security-operators
  namespace: propdev-smart-home
subjects:
  - kind: Group
    name: propdev-security-operators
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: propdev-smart-home-secret-reader
  apiGroup: rbac.authorization.k8s.io
'@
