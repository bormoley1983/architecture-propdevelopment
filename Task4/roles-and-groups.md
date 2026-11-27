# Задание 4. Роли и группы Kubernetes

## Модель доступа

Доступ выдаётся группам организации, а не отдельным людям. Kubernetes не хранит
обычные пользовательские учётные записи: этот пример использует клиентские
сертификаты X.509, где `CN` задаёт имя пользователя, а `O` — группу. Группу
передаёт API server после проверки сертификата; создавать объект Group в кластере
не требуется.

| Роль Kubernetes | Полномочия | Группа пользователей и область действия |
|---|---|---|
| `propdev-cluster-viewer` (`ClusterRole`) | Просмотр pods, services, endpoints, events, workloads, ingress, network policies, namespaces и nodes. Только `get/list/watch`; доступ к Secrets, ConfigMaps, логам pods и изменению ресурсов не предоставляется. | `propdev-cluster-viewers`: BI-аналитики, операционные менеджеры и владельцы продуктов. Привязка cluster-wide, только чтение перечисленных ресурсов. |
| `propdev-namespace-configurator` (`ClusterRole` через namespaced `RoleBinding`) | Создание, чтение, изменение и удаление workloads, services, ConfigMaps, jobs, ingress и network policies; только чтение pods/events/replicasets. Нет прямых прав на Secrets, RBAC, service accounts, namespaces, nodes или `pods/exec`. | `propdev-app-configurators`: DevOps и инженеры продуктовых команд; RoleBinding только в `propdev-sales`, `propdev-residents` и `propdev-data`. |
| `propdev-namespace-configurator` (`ClusterRole` через namespaced `RoleBinding`) | Те же полномочия, но ограниченные финансовым namespace; роль не даёт прав за его пределами. | `propdev-finance-configurators`: назначенные операторы финансового домена; RoleBinding только в `propdev-finance`. |
| `propdev-smart-home-secret-reader` (`Role`) | Только `get` одного секрета `smart-home-partner-client`; без `list`, `watch`, изменения или удаления секретов. | `propdev-security-operators`: специалист ИБ и назначенный заместитель; RoleBinding только в `propdev-smart-home`. |
| Встроенный `cluster-admin` | Полное управление кластером, включая RBAC и все Secrets. | Не назначается ни одной постоянной пользовательской группе в этих скриптах. Используется только bootstrap-администратором Minikube для настройки и аварийного восстановления. |

## Namespace и границы доверия

Скрипты создают отдельные namespace:

- `propdev-sales` — системы продаж;
- `propdev-residents` — сервисы собственников и ЖКУ;
- `propdev-data` — DWH/BI;
- `propdev-finance` — финансовые системы;
- `propdev-smart-home` — интеграция умного дома и её секрет партнёра.

Разделение namespace согласуется с доменами PropDevelopment и не позволяет
обычной группе конфигураторов менять финансовые системы или интеграцию умного
дома. Имена namespace в тестовом кластере задаются как пример; перед production
использованием их нужно сопоставить с реальным размещением приложений.

### Ограничение Kubernetes RBAC

Отсутствие прямого `get secrets` само по себе не защищает секрет от пользователя,
который может изменить workload в том же namespace: он потенциально может
запустить pod, которому смонтирован Secret. Поэтому общий конфигуратор не получает
RoleBinding в `propdev-smart-home`, где находится `smart-home-partner-client`.
Для рабочих namespace следует хранить только секреты, доступ к которым разрешён
владельцам этих workloads, ограничивать ServiceAccount и использовать admission
контроль для запрета небезопасных pod spec. Роль конфигуратора намеренно не
включает `pods/exec` и RBAC-ресурсы.

## Состав файлов и порядок запуска

1. `create-users.ps1` — формирует четыре клиентских сертификата через Kubernetes
   CertificateSigningRequest и отдельные kubeconfig-файлы. Приватные ключи
   сохраняются вне репозитория в `%USERPROFILE%\.kube\propdev-task4-users`.
2. `create-roles.ps1` — создаёт namespace, ClusterRole для чтения и конфигурации,
   а также точечную Role для чтения секрета.
3. `bind-users.ps1` — привязывает группы пользователей к ClusterRole/Role в
   разрешённых namespace.

Запускайте скрипты с административным kubeconfig Minikube и из PowerShell 7:

```powershell
.\create-users.ps1
.\create-roles.ps1
.\bind-users.ps1
```

Скрипты проверяют, что текущий контекст kubectl называется `minikube`, и
отказываются применять изменения к любому другому кластеру.

## Проверки после запуска

Сначала проверяйте права от имени каждой отдельной kubeconfig-учётной записи:

```powershell
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\bi-analyst-01.kubeconfig" auth can-i list pods --all-namespaces
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\bi-analyst-01.kubeconfig" auth can-i get secrets -n propdev-smart-home
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\devops-operator-01.kubeconfig" auth can-i patch deployments -n propdev-sales
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\devops-operator-01.kubeconfig" auth can-i patch deployments -n propdev-finance
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\finance-operator-01.kubeconfig" auth can-i patch deployments -n propdev-finance
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\security-officer-01.kubeconfig" auth can-i get secret/smart-home-partner-client -n propdev-smart-home
kubectl --kubeconfig "$HOME\.kube\propdev-task4-users\security-officer-01.kubeconfig" auth can-i list secrets -n propdev-smart-home
```

Ожидаемые ответы по порядку: `yes`, `no`, `yes`, `no`, `yes`, `yes`, `no`.
Секрет `smart-home-partner-client` намеренно не создаётся скриптами: значение
должно поступать из защищённого хранилища секретов, а не из репозитория.

## Ограничения демонстрационного решения

Пользовательские сертификаты выдаются через CSR с помощью текущего
административного контекста Minikube; операция `kubectl certificate approve`
требует административных полномочий. В production выдачу и ротацию сертификатов
следует автоматизировать через утверждённый корпоративный IdP/PKI. Не передавайте
приватные ключи через Git и не храните их в общем каталоге.
