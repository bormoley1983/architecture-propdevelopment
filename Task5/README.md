# Задание 5. Сетевая изоляция UI и API

## Политика

Основной артефакт — [non-admin-api-allow.yaml](./non-admin-api-allow.yaml).
Он создаёт выделенный namespace `propdev-network-policy-lab` и четыре
NetworkPolicy:

- `front-end` ↔ `back-end-api`;
- `admin-front-end` ↔ `admin-back-end-api`.

Для каждой роли политика ограничивает и входящий, и исходящий трафик. Новые
соединения разрешены только к парному UI/API по TCP/80. Ответный трафик
установленного соединения разрешается механизмом stateful tracking Kubernetes
NetworkPolicy. Для DNS отдельно разрешены UDP/TCP 53 только к CoreDNS в
`kube-system`, чтобы внутри namespace работали имена Kubernetes Service.

Пиры с `podSelector` без `namespaceSelector` выбираются только в том же
namespace. Ни одна политика не разрешает связь между обычной и admin-парой.
NetworkPolicy разрешает трафик аддитивно: если в namespace существуют другие
политики с более широкими разрешениями, итоговый доступ может быть шире. Для
проверки используйте чистый выделенный namespace без дополнительных политик.

## Перед запуском

NetworkPolicy должна поддерживаться и применяться сетевым плагином (CNI).
Например, для лабораторного Minikube можно включить Calico:

```powershell
minikube start --cni=calico
kubectl config current-context
```

Перед применением убедитесь, что контекст — целевой Minikube, а не другой
доступный кластер. В среде без CNI, который реализует NetworkPolicy, YAML
создастся, но изоляция трафика фактически работать не будет.

## Развёртывание

Сначала примените namespace и политики:

```powershell
kubectl apply -f .\Task5\non-admin-api-allow.yaml
```

Затем создайте четыре Nginx Pod и одноимённые Service в этом namespace:

```powershell
kubectl run front-end-app --image=nginx --labels=role=front-end --expose --port=80 --namespace=propdev-network-policy-lab
kubectl run back-end-api-app --image=nginx --labels=role=back-end-api --expose --port=80 --namespace=propdev-network-policy-lab
kubectl run admin-front-end-app --image=nginx --labels=role=admin-front-end --expose --port=80 --namespace=propdev-network-policy-lab
kubectl run admin-back-end-api-app --image=nginx --labels=role=admin-back-end-api --expose --port=80 --namespace=propdev-network-policy-lab
kubectl wait --for=condition=Ready pod --all --timeout=180s --namespace=propdev-network-policy-lab
```

## Проверка

Для теста запустите временный Alpine Pod с той же ролью, что и UI-источник.
Метка нужна потому, что изолированному Pod без разрешённой роли политика
запретит обращаться к сервисам приложения:

```powershell
kubectl run test-front-end --image=alpine --labels=role=front-end --restart=Never --namespace=propdev-network-policy-lab --command -- sleep 3600
kubectl wait --for=condition=Ready pod/test-front-end --timeout=120s --namespace=propdev-network-policy-lab
kubectl exec test-front-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://back-end-api-app
kubectl exec test-front-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://admin-back-end-api-app
```

Первый запрос должен успешно вернуть страницу Nginx, второй должен завершиться
таймаутом или сетевым отказом. Проверьте обратные инициированные соединения,
создав временные Pod для остальных ролей:

```powershell
kubectl run test-back-end --image=alpine --labels=role=back-end-api --restart=Never --namespace=propdev-network-policy-lab --command -- sleep 3600
kubectl run test-admin-front-end --image=alpine --labels=role=admin-front-end --restart=Never --namespace=propdev-network-policy-lab --command -- sleep 3600
kubectl run test-admin-back-end --image=alpine --labels=role=admin-back-end-api --restart=Never --namespace=propdev-network-policy-lab --command -- sleep 3600
kubectl wait --for=condition=Ready pod --all --timeout=120s --namespace=propdev-network-policy-lab
kubectl exec test-back-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://front-end-app
kubectl exec test-back-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://admin-front-end-app
kubectl exec test-admin-front-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://admin-back-end-api-app
kubectl exec test-admin-front-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://back-end-api-app
kubectl exec test-admin-back-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://admin-front-end-app
kubectl exec test-admin-back-end --namespace=propdev-network-policy-lab -- wget -qO- --timeout=3 http://front-end-app
```

Для каждой пары запрос внутри пары должен проходить; запросы к другой паре —
блокироваться. Команды для запрещённых запросов ожидаемо завершаются с
ненулевым кодом возврата.

Проверьте метки и политики:

```powershell
kubectl get pods,services --show-labels --namespace=propdev-network-policy-lab
kubectl get networkpolicy --namespace=propdev-network-policy-lab
```

Временные тестовые Pod удалите после проверки:

```powershell
kubectl delete pod test-front-end --namespace=propdev-network-policy-lab
kubectl delete pod test-back-end test-admin-front-end test-admin-back-end --namespace=propdev-network-policy-lab
kubectl delete namespace propdev-network-policy-lab
```

NetworkPolicy управляет сетевыми потоками, а не подтверждает личность Pod:
для production-сценария нужно также ограничить создание/изменение меток RBAC и
политиками admission control.
