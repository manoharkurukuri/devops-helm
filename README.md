# Notes App: Helm, Kustomize, and Argo CD

This repository describes three environments in one local Kubernetes cluster.
It does not provision MongoDB, database users, application credentials, or the
Gateway/certificate controllers. The `prod` environment is a production-practice
environment, not a production security or availability boundary.

## How the tools fit together

- **Helm** renders the chart's templates using values: Deployments, Services,
  ConfigMaps, Gateway resources, Issuers, and Certificates.
- **Kustomize** customizes the rendered objects without copying the chart. A
  **base** contains shared configuration; an **overlay** adds environment settings.
- **Argo CD** watches Git, renders one overlay per Application, compares it with
  the cluster, and applies changes when you sync.
- **Kubernetes** runs the resulting workloads.

The flow is Git -> Helm rendering -> Kustomize overlay -> Argo CD sync -> Kubernetes.
`kustomize build` only prints YAML; it never deploys anything. Argo CD `Synced`
means the live resources match Git; `Healthy` is a separate health assessment.
Helm rendering through Kustomize does not create a Helm release or Helm rollback
history for the application. Argo CD itself is installed as a Helm release.

## Environment settings

| Environment | Argo CD Application | Namespace | HTTP | HTTPS | Sync policy |
| --- | --- | --- | --- | --- | --- |
| dev | fullstack-dev | devops-app | 30080 | 31818 | Manual for migration; enable automation after verification |
| stage | fullstack-stage | devops-app-stage | 30081 | 31819 | Manual |
| prod | fullstack-prod | devops-app-prod | 30083 | 31820 | Manual |

Each environment starts with one backend and one frontend replica and the chart's
existing resource requests/limits. Check node capacity before scaling. NodePorts
must be free cluster-wide; port 30082 is reserved for the optional Argo webhook
example. Gateway listeners remain on ports 80 and 443; the NodePorts expose them.

The configured worker IP is `192.168.252.13`. Frontend API URLs are respectively
`https://192.168.252.13:31818/api`, `https://192.168.252.13:31819/api`, and
`https://192.168.252.13:31820/api`. These are planned endpoints until deployed.

## Repository layout and ownership

```text
kustomization.yaml                  # Convenience entrypoint: dev overlay
helm-notes-app/
  kustomization.yaml                # Shared Helm-rendering base
  Chart.yaml
  values.yaml                       # Common defaults
  environments/dev/
    backend.yaml                    # Existing CI-owned backend image tag
    frontend.yaml                   # Existing CI-owned frontend image tag
  templates/
kustomize/overlays/
  dev/kustomization.yaml
  stage/kustomization.yaml
  prod/kustomization.yaml
bootstrap/
  argocd-values.yaml                # Values for the Argo CD installation
  argocd-application.yaml           # Existing dev Application, migrated in place
  argocd-application-stage.yaml
  argocd-application-prod.yaml
test/kustomize_test.rb               # Offline rendering and behavior checks
.github/workflows/helm-check.yml
```

Overlays reference `../../../helm-notes-app`. The base uses `chartHome: ..` and
chart name `helm-notes-app`, with all values files inside its own directory.
An overlay cannot use an ancestor directory as a base: Kustomize rejects that
layout as a cycle. Default load restrictions remain enabled.

The release name is `fullstack`, matching the existing dev Application. Resource
names such as `fullstack-backend` are reused in separate namespaces. We do not add
name prefixes that could break Gateway or Service references.

Kustomize 5.8.1+ skips namespace transformation on Helm-generated resources.
The base deliberately does not fix `helmCharts.namespace`: the overlay's
`namespace` flows into Helm. Chart templates explicitly render
`metadata.namespace` from `.Release.Namespace`. Keep both the overlay namespace
and its ConfigMap generator namespace aligned when adding an environment.

Each overlay merges its API URL into the frontend ConfigMap. Names remain stable.
A Kustomize replacement copies that URL into the frontend pod-template annotation
`notes-app/config-api-url`, so changing the endpoint triggers a rollout. Helm's
existing checksum covers Helm-originated ConfigMap changes, but cannot detect
changes made later by Kustomize. If you add new post-render configuration fields,
extend the rollout mechanism and its tests to cover those fields too.

## Build and test locally

Use Kustomize **5.8.1** to match the inspected Argo CD repo-server; 5.8.3 also works.
CI tests Helm **3.19.0** and **4.2.1**. The regression suite uses Ruby and Minitest;
CI supplies Ruby 3.3.8. Check versions with `kustomize version`, `helm version
--short`, and `ruby --version`. Older Kustomize versions may not propagate the
overlay namespace into Helm as required by this layout.

```sh
helm lint helm-notes-app --strict
ruby test/kustomize_test.rb
kustomize build . --enable-helm > /tmp/notes-dev.yaml
kustomize build kustomize/overlays/stage --enable-helm > /tmp/notes-stage.yaml
kustomize build kustomize/overlays/prod --enable-helm > /tmp/notes-prod.yaml
```

The root build is exactly the dev overlay. You can select specific tool binaries
with `KUSTOMIZE=/path/to/kustomize HELM=/path/to/helm ruby test/kustomize_test.rb`.
The tests render all environments, inspect namespaces and resource references,
check routes/ports/TLS, and mutate temporary copies to verify image isolation and
frontend rollouts. They do not contact the cluster or edit CI-owned input files.
Do not routinely apply these rendered files with kubectl once Argo CD owns them.

## Prepare the cluster and credentials

Use the intended context explicitly. These examples use the existing `local`
context; verify it points to your lab before running any write command.

```sh
kubectl --context local get nodes -o wide
kubectl --context local get gatewayclasses
kubectl --context local get services -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODEPORTS:.spec.ports[*].nodePort'
helm --kube-context local list -n argocd
kubectl --context local -n argocd exec deployment/argocd-repo-server -- kustomize version
kubectl --context local -n argocd exec deployment/argocd-repo-server -- helm version --short
```

Verify Envoy Gateway, Gateway API CRDs, the `envoy-gateway` GatewayClass, and
cert-manager are installed and healthy. Confirm image pull access and sufficient
capacity for six application pods plus three Envoy data planes. The checked-in
image tags were seeded from dev; verify those artifacts still exist before sync.

Namespaces do not isolate databases. Provision separate MongoDB databases/users
and a different JWT secret for each environment. The backend requires a
namespace-local Secret named `backend-secrets` with keys `DB_URL` and `JWT_SECRET`.
Do not reuse dev's database credentials or overwrite its existing Secret.

Prefer your existing secret manager. For manually managed lab credentials, supply
protected env files outside this checkout, such as
`$HOME/.config/notes-app/stage.env` and `prod.env`, with those two keys. Do not put
credentials in Git, chat, shell history, or rendered manifest artifacts. Run the
following only after those protected files and separate databases are ready:

```sh
for environment in stage prod; do
  namespace="devops-app-${environment}"
  kubectl --context local create namespace "$namespace" --dry-run=client -o yaml |
    kubectl --context local apply -f -
  kubectl --context local -n "$namespace" create secret generic backend-secrets \
    --from-env-file="$HOME/.config/notes-app/${environment}.env"
done
```

The Secret creation intentionally fails if one already exists; investigate its
owner instead of overwriting it. `CreateNamespace=true` in an Application cannot
create the required database or credentials. Verify only Secret metadata when
checking availability; do not print secret values.

## Migrate dev safely

1. Record the current Git revision and dev resource inventory. If another
   controller manages this Application, coordinate its desired configuration too.
2. Pause live dev auto-sync **before publishing chart changes**, because its current
   direct-Helm source also follows `main`:

   ```sh
   kubectl --context local -n argocd patch application fullstack-dev --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   ```

3. Review the changes, run the checks, and publish the configuration to the
   Application's configured repository and `main` branch. Argo CD cannot read
   uncommitted local files. No branch or commit is created by the validation tools.
4. Enable Helm inflation in Argo CD using the installation values, not `kubectl
   apply -f bootstrap/argocd-values.yaml`. The inspected installation uses chart
   `argo-cd-10.11.7`; verify the installed version and preserve it:

   ```sh
   helm repo add argo https://argoproj.github.io/argo-helm
   helm repo update argo
   helm upgrade argocd argo/argo-cd --kube-context local --namespace argocd \
     --version 10.11.7 --reuse-values -f bootstrap/argocd-values.yaml
   kubectl --context local -n argocd get configmap argocd-cm \
     -o jsonpath='{.data.kustomize\.buildOptions}{"\n"}'
   ```

   The result must include `--enable-helm`. This setting is global to Kustomize
   Applications in this Argo CD instance. Do not add `LoadRestrictionsNone`.
   If repo-server still uses cached build settings, restart its Deployment and
   wait for readiness before retrying manifest generation.
5. Update the existing Application, without creating a second owner for dev:

   ```sh
   kubectl --context local apply --dry-run=server -f bootstrap/argocd-application.yaml
   kubectl --context local apply -f bootstrap/argocd-application.yaml
   kubectl --context local -n argocd port-forward service/argocd-server 8081:80
   ```

6. Open `http://localhost:8081`, refresh `fullstack-dev`, and review the diff.
   Deployment, Service, ConfigMap, Gateway, and certificate names should remain
   unchanged. The frontend rollout annotation and updated Helm checksums can
   restart pods. Do not proceed if unexpected resource deletions or renames appear.
7. Sync manually with pruning unchecked. Verify health, certificates, and app
   behavior before enabling automation. Zero downtime is not guaranteed with
   one replica and unverified spare capacity.
8. Change `spec.syncPolicy.automated.enabled` to `true` in the dev Application
   file, review/publish that change, and reapply the Application. Its configured
   `prune: true` and `selfHeal: true` then become active. Publishing the file alone
   does not update the Application object unless a separate bootstrap manager
   owns it. Do not enable auto-sync for stage or prod.

## Deploy stage, then prod

After their namespace-local credentials exist and dev migration is verified:

```sh
kubectl --context local apply -f bootstrap/argocd-application-stage.yaml
```

Refresh and inspect `fullstack-stage` in Argo CD, manually sync, and complete the
checks below. Only then create `fullstack-prod` using
`kubectl --context local apply -f bootstrap/argocd-application-prod.yaml`, inspect
its diff, and manually sync it. Stage/prod have no automatic sync policy.

Check each namespace, substituting its name below:

```sh
namespace=devops-app-stage
kubectl --context local -n "$namespace" rollout status deployment/fullstack-backend
kubectl --context local -n "$namespace" rollout status deployment/fullstack-frontend
kubectl --context local -n "$namespace" get gateways,httproutes,certificates
kubectl --context local -n "$namespace" wait --for=condition=Ready \
  certificate/notes-app-certificate --timeout=120s
```

Check Gateway `Accepted`/`Programmed` and HTTPRoute `Accepted`/`ResolvedRefs`
conditions, not only pod readiness. Confirm Envoy's generated Services use the
expected NodePorts. Test login and notes create/read/update/delete in every
environment. Browser network requests must use the matching API port, and test
data and JWTs must not cross environments.

Each namespace creates its own lab CA. Certificates must cover the worker IP;
trust each environment's CA separately. You can extract just the public CA
certificate (not the private key) for inspection and local trust:

```sh
kubectl --context local -n "$namespace" get secret notes-local-ca-key \
  -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A > "/tmp/${namespace}-ca.crt"
openssl x509 -in "/tmp/${namespace}-ca.crt" -noout -subject -issuer -fingerprint -sha256
curl --cacert "/tmp/${namespace}-ca.crt" https://192.168.252.13:31819/
```

Use the matching HTTPS port for other environments. Verify the CA before adding
it to browser/OS trust. Do not treat `curl -k` or bypassing browser warnings as
successful TLS validation. If the worker IP changes, update every overlay's
`API_URL`, the common Helm default, and the Certificate IP SANs together.

Namespaces are not network firewalls. This lab has no added NetworkPolicies,
production RBAC boundaries, database backup system, or availability guarantees.
Cookies are not port-scoped; use separate browser profiles if authentication uses
cookies, or move to separate hostnames before relying on browser isolation.

## Promote tested images

Existing CI can keep updating the two dev image-value files. Those files must
remain image-tag-only; the test suite enforces this contract. Do not add replicas,
environment settings, or credentials there.

Stage and prod explicitly pin both images in their overlays. Promotion is a
reviewed Git change, not rebuilding an image or just refreshing Argo CD:

1. Let CI publish images and update dev. Verify dev after its sync.
2. Record the tested frontend/backend image pair. In the stage overlay's `images`
   entries, set both `newTag` values to that pair, or use verified `digest` values
   instead of `newTag`. Use immutable artifacts; never use `latest`.
3. Run `ruby test/kustomize_test.rb`, review/publish the change, then manually sync
   stage and smoke-test it.
4. Promote exactly the same pair to prod through another reviewed change, then
   manually sync prod. Do not rebuild for prod.

Changing only dev image tags leaves stage/prod rendered manifests unchanged, as
the mutation test verifies. Common chart/default changes still affect all three
desired configurations: stage/prod can become `OutOfSync`, but manual sync stops
automatic deployment. This is not complete isolation of every chart revision.

## Rollback and troubleshooting

Revert the affected environment's image pins or configuration in Git, review the
rendered diff, and sync it. Preserve namespaces, databases, and credentials.
For a failed dev migration, keep automation disabled and restore the known-good
Application source/revision after reviewing resource identities. An Argo CD
history rollback alone is not a lasting fix while Git still describes the change.

| Symptom | Check |
| --- | --- |
| `must specify --enable-helm` | Local build flag or Argo CD `configs.cm.kustomize.buildOptions` |
| Chart not found | Base `chartHome: ..` and chart name `helm-notes-app` |
| Namespace mismatch or ConfigMap merge error | Kustomize version, overlay/generator namespace, and chart `.Release.Namespace` |
| `CreateContainerConfigError` | Namespace-local `backend-secrets` with both required keys |
| `ImagePullBackOff` | Promoted tag/digest exists and registry access works |
| Gateway not programmed | Controller/CRDs, GatewayClass, and cluster-wide NodePort conflicts |
| Browser TLS error | Certificate Ready, correct IP SAN, and matching local CA trust |
| Wrong API environment | Frontend ConfigMap, pod annotation, rollout status, and browser network requests |
| Argo CD shows no local changes | Publish to the configured Git repo/branch, then refresh |
| Application remains OutOfSync | Stage/prod and initial dev intentionally require manual sync |