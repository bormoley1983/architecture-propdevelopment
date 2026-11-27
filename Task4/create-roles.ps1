Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kubectl = Get-Command kubectl -ErrorAction Stop
$currentContext = (& $kubectl.Source config current-context).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the current kubectl context.'
}
if ($currentContext -ne 'minikube') {
    throw "Refusing to create roles: current context is '$currentContext', not 'minikube'."
}

function Invoke-ApplyManifest {
    param([Parameter(Mandatory)][string]$Manifest)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "propdev-task4-$([guid]::NewGuid().ToString('N')).yaml"
    [System.IO.File]::WriteAllText($path, $Manifest, [System.Text.UTF8Encoding]::new($false))
    try {
        & $kubectl.Source apply -f $path
        if ($LASTEXITCODE -ne 0) {
            throw 'kubectl apply failed while creating a namespace or RBAC role.'
        }
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

$namespaces = @(
    'propdev-sales',
    'propdev-residents',
    'propdev-data',
    'propdev-finance',
    'propdev-smart-home'
)
foreach ($namespace in $namespaces) {
    Invoke-ApplyManifest -Manifest @"
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    app.kubernetes.io/part-of: propdevelopment
"@
}

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-cluster-viewer
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "events", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch"]
'@

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: propdev-namespace-configurator
rules:
  - apiGroups: [""]
    resources: ["pods", "events", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
'@

Invoke-ApplyManifest -Manifest @'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: propdev-smart-home-secret-reader
  namespace: propdev-smart-home
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["smart-home-partner-client"]
    verbs: ["get"]
'@
