# Kustomize Explained: This Notes App From Build to Deployment

A beginner's guide to Kustomize, Helm, and Argo CD in this repository.

**Read this first:** commands in this guide are instructions, not a script to run
from top to bottom. Some inspect files, some generate YAML, and some change the
cluster. Every command block states its purpose and effect. Run repository
commands from the root of this checkout. Never put real passwords in this guide.

This guide documents the implementation reviewed on **2026-11-11**. During the
previous session, stage and prod were manually synced and verified as
`Synced / Healthy`. That is a historical observation, not a live health guarantee.
Use the status commands below to check their current state. Do not repeat initial
setup or migration steps on an already configured environment without a reason.

## Contents

1. [What Kustomize is](#1-what-kustomize-is)
2. [The vocabulary](#2-the-vocabulary)
3. [Helm, Kustomize, Argo CD, and Kubernetes](#3-helm-kustomize-argo-cd-and-kubernetes)
4. [Our three-environment architecture](#4-our-three-environment-architecture)
5. [Repository layout and ownership](#5-repository-layout-and-ownership)
6. [How our base renders Helm](#6-how-our-base-renders-helm)
7. [How an overlay changes the application](#7-how-an-overlay-changes-the-application)
8. [How browser traffic reaches the application](#8-how-browser-traffic-reaches-the-application)
9. [Implementation decisions and lessons](#9-implementation-decisions-and-lessons)
10. [Command conventions and prerequisites](#10-command-conventions-and-prerequisites)
11. [Build and test without deploying](#11-build-and-test-without-deploying)
12. [Prepare environment credentials](#12-prepare-environment-credentials)
13. [Configure Argo CD and migrate dev](#13-configure-argo-cd-and-migrate-dev)
14. [Create Applications and manually sync](#14-create-applications-and-manually-sync)
15. [Verify workloads, routing, and HTTPS](#15-verify-workloads-routing-and-https)
16. [Promote images and roll back](#16-promote-images-and-roll-back)
17. [What CI validates](#17-what-ci-validates)
18. [Troubleshooting and everyday workflow](#18-troubleshooting-and-everyday-workflow)

## 1. What Kustomize Is

Kubernetes applications are described using YAML resources such as Deployments,
Services, and ConfigMaps. A small application quickly needs several YAML files.
If you copy all of them for dev, stage, and prod, shared changes must be repeated
three times. The copies can drift apart accidentally.

**Kustomize combines shared resources with environment-specific changes and
produces the final Kubernetes YAML.** It operates on structured YAML fields,
not arbitrary text substitutions. It understands common Kubernetes relationships,
such as a Deployment referring to a ConfigMap.

For example, the same backend can have one replica in dev and more replicas in
prod, while sharing its container ports, health probes, and Service definition.
In this local project all three initially use one replica to conserve capacity.

```mermaid
flowchart LR
    BASE[Shared application configuration]
    BASE --> DEV[Dev overlay]
    BASE --> STAGE[Stage overlay]
    BASE --> PROD[Prod overlay]
    DEV --> DY[Dev Kubernetes YAML]
    STAGE --> SY[Stage Kubernetes YAML]
    PROD --> PY[Prod Kubernetes YAML]
```

Important properties:

- A build does not modify the source manifests.
- A build does not install anything in Kubernetes.
- A build does not require the target namespace or database to exist.
- The output is ordinary Kubernetes YAML, not a special runtime format.
- Kustomize does not need its own in-cluster controller for this workflow.
- Kustomize does not build container images or provision database users.
- It normally customizes plain manifests; Helm rendering is an optional integration.

The standalone command is `kustomize`. Kubectl also embeds a Kustomize version,
but its version and available flags can differ. This project uses the standalone
tool with explicit Helm support to match Argo CD's build behavior.

## 2. The Vocabulary

| Term | Meaning | Example in this project |
| --- | --- | --- |
| Resource | A Kubernetes object definition | Deployment `fullstack-backend` |
| Kustomization | Instructions for a Kustomize build | A file declaring resources, images, and patches |
| Base | Reusable configuration consumed by overlays | The Helm-rendering configuration inside the chart directory |
| Overlay | A base plus environment-specific changes | The stage namespace, ports, API URL, and image pins |
| Transformation | A structured change to resources | Setting replicas or image versions |
| Patch | A targeted modification of an existing object | Replacing the EnvoyProxy NodePort list |
| Generator | Creates or merges a resource from inputs | Merging the frontend API URL into a ConfigMap |
| Replacement | Copies a value from one resource field to another | API URL into a Deployment pod annotation |
| Render/build | Produce final YAML | `kustomize build` |
| Sync | Apply Git's desired configuration to the cluster | An Argo CD manual sync |
| Reconciliation | Repeated comparison of desired and live state | Argo CD detecting a changed image |

A Kustomize `Kustomization` file is a build instruction. It is not a built-in
Kubernetes workload you send to the API server with `kubectl apply -f`.
Some other tools define a custom resource also called `Kustomization`; that is
not the resource type used by this repository's local build files.

Two Kustomize features need care:

- Name prefixes and suffixes can update supported references, but custom-resource
  references may require extra configuration. We preserve existing resource names.
- Labels are useful for organization, but changing Deployment selectors can cause
  immutable-field errors. We do not introduce selector-changing environment labels.

## 3. Helm, Kustomize, Argo CD, and Kubernetes

These tools cooperate; they are not interchangeable.

| Tool | Input | Responsibility | Does it deploy here? |
| --- | --- | --- | --- |
| Helm | Chart templates and values | Generate the shared Kubernetes objects | No; it is used for application rendering |
| Kustomize | Helm-generated objects and overlay | Apply environment customization | No |
| Argo CD | Git repository, branch, and overlay path | Render, compare, and sync resources | Yes |
| Kubernetes | Applied resources | Schedule pods and reconcile workloads | Runs the application |

```mermaid
flowchart TD
    GIT[Git repository and selected revision] --> ARGO[Argo CD Application]
    ARGO --> REPO[Repo-server reads overlay]
    REPO --> BASE[Overlay loads shared base]
    BASE --> HELM[Helm renders templates and values]
    HELM --> CUSTOM[Kustomize applies overlay changes]
    CUSTOM --> DESIRED[Desired Kubernetes manifests]
    DESIRED --> DIFF[Argo CD compares desired and live state]
    LIVE[Current cluster resources] --> DIFF
    DIFF --> APPROVAL[Manual sync or enabled automatic sync]
    APPROVAL --> API[Kubernetes API server]
    API --> CONTROLLERS[Controllers create and update workloads]
    CONTROLLERS --> LIVE
```

Argo CD's repo-server renders manifests. Its application-controller observes and
synchronizes application state. Neither needs to install a Helm release for this
app: Helm is a rendering tool inside the build. Therefore, use Git and Argo CD
for application rollback, not `helm rollback` on a nonexistent notes-app release.

**Argo CD itself is different:** it was installed using the Argo CD Helm chart,
so changing its installation settings uses `helm upgrade` on release `argocd`.

### Sync status is different from health

| State | What it tells you |
| --- | --- |
| OutOfSync | Desired and live resources differ, possibly because resources are missing |
| Synced | The live resource configuration matches the desired configuration |
| Missing | An expected resource has not been created |
| Progressing | Resources exist but are still becoming ready |
| Healthy | Resources satisfy Argo CD's applicable health checks |
| Degraded | A resource has a reported health problem |

Healthy pods are not proof that login, MongoDB access, or every application route
works. This chart uses TCP probes, so application-level smoke tests remain necessary.

## 4. Our Three-Environment Architecture

All environments share one local cluster. Each has a separate namespace and a
separate Argo CD Application.

| Environment | Application | Namespace | HTTP NodePort | HTTPS NodePort |
| --- | --- | --- | --- | --- |
| dev | fullstack-dev | devops-app | 30080 | 31818 |
| stage | fullstack-stage | devops-app-stage | 30081 | 31819 |
| prod | fullstack-prod | devops-app-prod | 30083 | 31820 |

The worker IP configured in the app and certificates is `192.168.252.13`.
Port `30082` is reserved for the optional Argo CD webhook example.

```mermaid
flowchart TB
    subgraph CLUSTER[One local Kubernetes cluster]
        ARGO[Argo CD in argocd namespace]
        subgraph DEV[devops-app]
            DAPP[Frontend and backend]
            DCONF[ConfigMaps and backend-secrets]
            DGW[Gateway, HTTPRoute, EnvoyProxy, and TLS resources]
        end
        subgraph STAGE[devops-app-stage]
            SAPP[Frontend and backend]
            SCONF[ConfigMaps and backend-secrets]
            SGW[Gateway, HTTPRoute, EnvoyProxy, and TLS resources]
        end
        subgraph PROD[devops-app-prod]
            PAPP[Frontend and backend]
            PCONF[ConfigMaps and backend-secrets]
            PGW[Gateway, HTTPRoute, EnvoyProxy, and TLS resources]
        end
        ARGO --> DEV
        ARGO --> STAGE
        ARGO --> PROD
    end
    DAPP --> DDB[Dev MongoDB database]
    SAPP --> SDB[Stage MongoDB database]
    PAPP --> PDB[Prod MongoDB database]
```

The database boxes represent separately provisioned databases, not databases
installed by this chart. They may share a MongoDB server, but should use distinct
database names and restricted users. Their actual separation must be verified.

The workload name `fullstack-backend` is safe to reuse because namespaced resource
identity includes the namespace. NodePorts, however, must be unique cluster-wide.

**Limitations:** namespace separation does not automatically provide network
isolation, database isolation, backups, high availability, or production access
controls. Here, `prod` is a production-practice environment on a local cluster.

## 5. Repository Layout and Ownership

```text
devops-helm/
  kustomization.yaml
  helm-notes-app/
    kustomization.yaml
    Chart.yaml
    values.yaml
    environments/dev/
      backend.yaml
      frontend.yaml
    templates/
  kustomize/overlays/
    dev/kustomization.yaml
    stage/kustomization.yaml
    prod/kustomization.yaml
  bootstrap/
    argocd-values.yaml
    argocd-application.yaml
    argocd-application-stage.yaml
    argocd-application-prod.yaml
  test/kustomize_test.rb
  .github/workflows/helm-check.yml
```

| File | What to change there |
| --- | --- |
| [Root entrypoint](kustomization.yaml) | Normally nothing; it points to dev for convenient local builds |
| [Helm-rendering base](helm-notes-app/kustomization.yaml) | Shared Helm rendering configuration |
| [Chart defaults](helm-notes-app/values.yaml) | Shared non-secret application defaults |
| [Dev backend image input](helm-notes-app/environments/dev/backend.yaml) | Backend tag updated by existing CI |
| [Dev frontend image input](helm-notes-app/environments/dev/frontend.yaml) | Frontend tag updated by existing CI |
| [Dev overlay](kustomize/overlays/dev/kustomization.yaml) | Dev configuration; images come from existing CI inputs |
| [Stage overlay](kustomize/overlays/stage/kustomization.yaml) | Stage configuration and both promoted image versions |
| [Prod overlay](kustomize/overlays/prod/kustomization.yaml) | Prod configuration and both promoted image versions |
| [Argo CD installation values](bootstrap/argocd-values.yaml) | Repo-server build options and Argo server settings |
| [Dev Application](bootstrap/argocd-application.yaml) | Dev Git source, destination, and sync policy |
| [Stage Application](bootstrap/argocd-application-stage.yaml) | Stage Git source and destination; manual sync |
| [Prod Application](bootstrap/argocd-application-prod.yaml) | Prod Git source and destination; manual sync |
| [Regression tests](test/kustomize_test.rb) | Checks of rendered configuration and environment isolation |
| [Validation workflow](.github/workflows/helm-check.yml) | Automated build and test jobs |

## 6. How Our Base Renders Helm

The shared base contains:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmGlobals:
  chartHome: ..

helmCharts:
  - name: helm-notes-app
    releaseName: fullstack
    valuesFile: values.yaml
    additionalValuesFiles:
      - environments/dev/backend.yaml
      - environments/dev/frontend.yaml
```

| Setting | Explanation |
| --- | --- |
| `apiVersion` and `kind` | Identify this as a Kustomize build configuration |
| `chartHome: ..` | From the chart directory, look in its parent for local charts |
| `name: helm-notes-app` | Select the directory containing the local chart |
| `releaseName: fullstack` | Preserve existing Helm-derived resource names |
| `valuesFile: values.yaml` | Load common defaults from inside the base directory |
| `additionalValuesFiles` | Load existing CI-owned dev image-tag overrides |

Path resolution is: base directory -> `..` -> `helm-notes-app`, which resolves to
the existing local chart. No remote chart repository is needed. The chart's
metadata name is `fullstack-notes-app`; Kustomize's local directory lookup must
still use the actual directory name `helm-notes-app`.

Later Helm values files override matching earlier values. In this repository the
two additional files contain only their respective component's image tag.
Stage/prod subsequently replace those rendered images using their own pins.

There is deliberately **no fixed `helmCharts.namespace`**. With the verified
Kustomize version, the overlay namespace is passed into Helm's release context.
The chart renders `.Release.Namespace` explicitly on every namespaced resource.

The root entrypoint simply contains:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kustomize/overlays/dev
```

It is a shortcut for dev, not another environment or an additional deployment.

## 7. How an Overlay Changes the Application

The following blocks explain the actual stage overlay. They are excerpts of one
configuration, not separate files to create.

### Load the base and choose a namespace

```yaml
resources:
  - ../../../helm-notes-app
namespace: devops-app-stage
```

From `kustomize/overlays/stage`, going up three directories reaches the repository
root, then selects the chart-local base. This avoids copying templates.

The namespace determines where namespaced resources are rendered. It does not
create a Namespace object by itself. Argo CD has `CreateNamespace=true`, but
credential provisioning usually creates the namespace before the first sync.

### Set replicas and pin images

```yaml
replicas:
  - name: fullstack-backend
    count: 1
  - name: fullstack-frontend
    count: 1
images:
  - name: mkurukuri/notes-backend
    newTag: "41810493933-1"
  - name: mkurukuri/notes-frontend
    newTag: "41810485793-1"
```

`replicas` selects the named workloads and sets the desired replica counts.
`images.name` matches a container image repository; `newTag` replaces its tag.
These are the initial pinned versions, not a promise that they remain the newest.
Verify registry availability before deployment. For stronger immutability, replace
`newTag` with a verified `digest: sha256:...` for the same repository.

Dev intentionally has no independent image pins: it consumes the existing CI
inputs. Stage and prod pin both images so a new dev build cannot promote itself.

### Set the frontend's API endpoint

```yaml
configMapGenerator:
  - name: fullstack-frontend-config
    namespace: devops-app-stage
    behavior: merge
    literals:
      - API_URL=https://192.168.252.13:31819/api
generatorOptions:
  disableNameSuffixHash: true
```

`behavior: merge` requires the existing Helm-rendered ConfigMap and merges data
into it. The generator's namespace must match that resource's namespace.
`literals` supplies non-secret `KEY=value` entries. The API URL is configuration,
not a credential.

Normally a generated ConfigMap can receive a content hash in its name, enabling
rollouts through updated references. Our Helm merge keeps the stable ConfigMap
name; we explicitly disable name suffix hashing and use the replacement below.

### Trigger a rollout when that endpoint changes

```yaml
replacements:
  - source:
      kind: ConfigMap
      name: fullstack-frontend-config
      fieldPath: data.API_URL
    targets:
      - select:
          kind: Deployment
          name: fullstack-frontend
        fieldPaths:
          - spec.template.metadata.annotations.notes-app/config-api-url
        options:
          create: true
```

The source is the final API URL in the ConfigMap. The target is an annotation
inside the frontend Deployment's **pod template**. `create: true` allows Kustomize
to add the annotation when it is absent.

```mermaid
flowchart LR
    EDIT[Overlay API URL changes] --> CM[ConfigMap data changes]
    CM --> COPY[Kustomize replacement copies API URL]
    COPY --> TEMPLATE[Pod-template annotation changes]
    TEMPLATE --> SYNC[Argo CD sync applies Deployment]
    SYNC --> ROLLOUT[Deployment creates replacement pods]
    ROLLOUT --> ENV[New pods read updated ConfigMap environment]
```

Changing a ConfigMap alone does not refresh environment variables in existing
containers. Also, Helm computes its existing config checksum before Kustomize
changes the URL. The replacement closes that gap without a manual restart.
Any new post-render configuration fields need equivalent rollout coverage.

### Give stage its own external ports

```yaml
patches:
  - target:
      group: gateway.envoyproxy.io
      version: v1alpha1
      kind: EnvoyProxy
      name: fullstack-proxy
    patch: |-
      - op: replace
        path: /spec/provider/kubernetes/envoyService/patch/value/spec/ports
        value:
          - port: 80
            protocol: TCP
            nodePort: 30081
          - port: 443
            protocol: TCP
            nodePort: 31819
```

The target identifies one EnvoyProxy custom resource. The embedded JSON Patch
replaces its nested Service port list. We replace the whole list explicitly
instead of assuming Kubernetes-style list merge keys apply to this custom schema.

`port` is the Envoy Service's HTTP or HTTPS port; `nodePort` is its external node
port. The backend and frontend Services stay internal `ClusterIP` Services.
Prod uses the same mechanism with ports `30083` and `31820`.

## 8. How Browser Traffic Reaches the Application

```mermaid
flowchart TD
    BROWSER[Browser requests worker IP on port 31819] --> NODE[NodePort Service for stage Envoy]
    NODE --> ENVOY[Envoy data plane]
    CERT[Stage TLS Secret] --> ENVOY
    GATEWAY[Stage Gateway HTTPS listener] -. configures .-> ENVOY
    ENVOY --> ROUTE[Stage HTTPRoute rules]
    ROUTE -->|Exact /api/config or /api/runtime-config| FS[Frontend Service]
    ROUTE -->|Prefix /api| BS[Backend Service]
    ROUTE -->|Prefix /| FS
    FS --> FP[Frontend pod]
    BS --> BP[Backend pod]
    BP --> DB[Stage MongoDB database]
```

The exact frontend configuration routes must stay ahead of the general `/api`
behavior conceptually; their more specific matches route to the frontend, not
the backend. TLS terminates at the Gateway's Envoy data plane. Certificate and
Issuer objects are reconciled by cert-manager to populate the TLS Secret.

Each namespace has its own local CA and certificate resources. A Ready certificate
means it was issued, not that your browser trusts its CA. Trust is a separate step.

## 9. Implementation Decisions and Lessons

### Starting point

Argo CD originally rendered the Helm chart directly for dev using release name
`fullstack`. The initial local Kustomize entry had a wrong chart-directory name,
which caused `no repo specified for pull, no chart found`. Correcting it to the
existing chart directory fixed local chart discovery.

### What changed

1. Kept the existing chart and CI image inputs instead of maintaining duplicate manifests.
2. Added a shared Kustomize base inside the chart directory.
3. Added dev, stage, and prod overlays, with stage/prod image pins and unique ports.
4. Added explicit namespaces to chart resources that previously relied on deployment-time defaults.
5. Preserved `fullstack-*` names and Deployment selectors for migration compatibility.
6. Added the frontend rollout annotation mechanism.
7. Changed Argo CD sources from direct Helm to environment overlay paths.
8. Enabled Helm inflation in Argo CD's Kustomize build options.
9. Added automated rendering and mutation tests, retaining existing Helm validation.
10. Manually synced stage and then prod after their credentials and Applications existed.

### Why the final layout differs from the first proposal

An overlay referencing the repository root as its base triggered Kustomize's
ancestor-directory cycle check. Moving the base into the chart directory made it
a sibling of the overlay tree. The root became a dev shortcut instead.

The inspected Kustomize 5.8.1 and 5.8.3 implementations skip namespace transformation
on Helm-generated resources. We removed a fixed base Helm namespace and rendered
`.Release.Namespace` on every namespaced chart resource. This was tested with the
actual Argo-compatible renderer, rather than relying only on YAML appearance.

Merging a generator into the existing Helm ConfigMap did not yield the planned
hash-suffixed name. We used a tested pod-template replacement instead. These
details matter when upgrading Kustomize: run the regression suite again.

### Resource inventory per environment

| Kind | Count | Purpose |
| --- | --- | --- |
| Deployment | 2 | Backend and frontend pods |
| Service | 2 | Internal access to backend and frontend |
| ConfigMap | 2 | Non-secret backend and frontend configuration |
| Certificate | 2 | Local CA certificate and application certificate |
| Issuer | 2 | Bootstrap self-signing and local CA issuance |
| EnvoyProxy | 1 | Envoy Service configuration, including NodePorts |
| Gateway | 1 | HTTP/HTTPS listeners and TLS references |
| HTTPRoute | 1 | Routing to frontend/backend Services |
| **Total rendered objects** | **13** | Does not count controller-generated child resources |

Pods, ReplicaSets, Envoy data-plane resources, and certificate Secrets are created
by controllers. `backend-secrets` is provisioned separately, not rendered here.

## 10. Command Conventions and Prerequisites

### How to read the commands

| Syntax | Meaning |
| --- | --- |
| `--context local` | Select the named kubectl context without changing your default |
| `--kube-context local` | The equivalent context selection for Helm |
| `-n NAME` / `--namespace NAME` | Select a Kubernetes namespace |
| `-f PATH` | Read a manifest or values file, depending on the command |
| `-o yaml` / `-o jsonpath=...` | Choose full YAML output or selected fields |
| `> PATH` | Write stdout to a file, replacing its previous contents |
| `\` at line end | Continue the same shell command on the next line |
| `|` | Pass the first command's stdout to the next command's stdin |
| `&&` | Run the next command only if the previous one succeeds |
| `$namespace` | Substitute the value of the shell variable named namespace |
| `--timeout=120s` | Stop waiting after two minutes; it does not repair the workload |

Do not assume the context called `local` always points to the intended cluster.
Inspect your configuration and nodes before running write commands.

**Read-only: check tools and cluster prerequisites.**

```sh
kustomize version
helm version --short
ruby --version
kubectl config current-context
kubectl config get-contexts local
kubectl --context local get nodes -o wide
kubectl --context local get gatewayclasses
kubectl --context local get services -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODEPORTS:.spec.ports[*].nodePort'
```

| Command | Explanation |
| --- | --- |
| `kustomize version` | Shows the local renderer version; the CI/Argo-compatible pin is 5.8.1 |
| `helm version --short` | Shows the Helm version without a long structured report |
| `ruby --version` | Checks the interpreter used by the local regression suite |
| `kubectl config current-context` | Shows the default context; explicit flags still take precedence |
| `kubectl config get-contexts local` | Shows which cluster/user the named context selects |
| `get nodes -o wide` | Checks node readiness and IPs, including the configured worker IP |
| `get gatewayclasses` | Checks that the expected GatewayClass exists; inspect controller health too |
| `get services -A ...` | Lists all namespaces' Services and allocated NodePorts to detect collisions |

Prerequisites include working Argo CD, Envoy Gateway, Gateway API CRDs,
cert-manager, reachable MongoDB, available images, and enough cluster capacity.
Installing those platforms from scratch is outside this application's chart.

## 11. Build and Test Without Deploying

**Local-only: render each environment.**

```sh
kustomize build . --enable-helm > /tmp/notes-dev.yaml
kustomize build kustomize/overlays/stage --enable-helm > /tmp/notes-stage.yaml
kustomize build kustomize/overlays/prod --enable-helm > /tmp/notes-prod.yaml
```

| Command part | Explanation |
| --- | --- |
| `build .` | Reads the root entrypoint, which loads the dev overlay |
| `build kustomize/overlays/stage` | Builds the stage overlay and its shared base |
| `build kustomize/overlays/prod` | Builds the prod overlay and its shared base |
| `--enable-helm` | Allows Kustomize to execute Helm inflation; required for this project |
| `> /tmp/notes-*.yaml` | Stores the generated manifests for inspection; no cluster change |

**Local-only: validate the chart and environment behavior.**

```sh
helm lint helm-notes-app --strict
helm template fullstack helm-notes-app --namespace devops-app \
  -f helm-notes-app/environments/dev/frontend.yaml \
  -f helm-notes-app/environments/dev/backend.yaml > /tmp/notes-helm-dev.yaml
ruby test/kustomize_test.rb
```

- `helm lint` checks chart structure and rendering conventions; `--strict` makes
  lint warnings fail the check. It does not contact the cluster.
- `helm template` renders the chart directly as release `fullstack`; the namespace
  and two values files reproduce the dev Helm inputs. It does not apply Kustomize
  overlay changes or install a release.
- `ruby test/kustomize_test.rb` runs the Minitest suite. It executes Helm/Kustomize,
  parses the output, and changes only temporary copies for mutation tests.
  The implementation passed 6 tests and 251 assertions; counts can evolve.

**Cluster validation without persistence, after the namespace exists:**

```sh
kubectl --context local apply --dry-run=server -f /tmp/notes-stage.yaml
kubectl --context local diff -f /tmp/notes-stage.yaml
```

`--dry-run=server` asks the API server to validate/admit the resources without
persisting them. It can catch missing CRDs and admission failures that a local
build cannot. `diff` compares the supplied configuration to the cluster; exit code
`1` means differences were found, not necessarily a failure. Values in diffs can
be sensitive if you later add Secret manifests, so keep secrets out of artifacts.

Once Argo CD owns the app, use its diff and sync for normal deployment. Do not
create a competing manual apply workflow for the same resources.

## 12. Prepare Environment Credentials

Skip creation for environments whose Secrets are already managed. The chart needs
`backend-secrets` in each namespace, containing `DB_URL` and `JWT_SECRET`.

Keep the env files outside Git under `$HOME/.config/notes-app/`. Example contents
below contain placeholders, not working credentials:

**Stage example:**

```dotenv
DB_URL=mongodb://STAGE_USER:URL_ENCODED_PASSWORD@MONGODB_HOST:27017/notes_stage?authSource=admin
JWT_SECRET=REPLACE_WITH_UNIQUE_STAGE_SECRET
```

**Prod example:**

```dotenv
DB_URL=mongodb://PROD_USER:URL_ENCODED_PASSWORD@MONGODB_HOST:27017/notes_prod?authSource=admin
JWT_SECRET=REPLACE_WITH_UNIQUE_PROD_SECRET
```

`DB_URL` must be your actual MongoDB URI, including any required TLS or replica-set
options. Atlas commonly supplies a `mongodb+srv://` URI: use the appropriate
provider connection string and the correct database. `authSource=admin` is correct
only when the user was created in that authentication database. Percent-encode
special characters in URI credentials. `localhost` inside a backend pod is the
pod itself, not your Mac or another database server.

For `kubectl --from-env-file`, use plain `KEY=value` lines with no `export`, no
surrounding quotes, and no spaces around `=`. Provision separate database users
with appropriately restricted permissions; these files do not create those users.

**Local-only preparation; enter credentials using your local editor.**

```sh
mkdir -p "$HOME/.config/notes-app"
chmod 700 "$HOME/.config/notes-app"
openssl rand -base64 64 | tr -d '\n'; printf '\n'
chmod 600 "$HOME/.config/notes-app/stage.env" "$HOME/.config/notes-app/prod.env"
```

- `mkdir -p` creates the directory if needed, without deleting an existing one.
- `chmod 700` restricts directory access to your account.
- `openssl rand -base64 64` generates 64 random bytes and encodes them. `tr` removes
  line wrapping; `printf` adds a final newline for readable terminal output. Run it
  separately for each environment and use the outputs as distinct JWT secrets.
- Create the two env files privately before running `chmod 600`; that command
  restricts existing files to owner read/write. It does not create their contents.

Never paste generated secrets into chat or commit these env files. Kubernetes
Secret base64 encoding is not encryption; use suitable RBAC and storage security.

**Cluster-changing: initial creation only, after databases and env files are ready.**

```sh
for environment in stage prod; do
  namespace="devops-app-${environment}"
  kubectl --context local create namespace "$namespace" --dry-run=client -o yaml |
    kubectl --context local apply -f - || break
  kubectl --context local -n "$namespace" create secret generic backend-secrets \
    --from-env-file="$HOME/.config/notes-app/${environment}.env" || break
done
```

| Part | Explanation |
| --- | --- |
| `for environment in stage prod` | Runs the body for stage, then prod |
| `namespace=...` | Selects the corresponding namespace name |
| `create namespace --dry-run=client -o yaml` | Generates a Namespace manifest locally |
| `apply -f -` | Reads that manifest from stdin and creates/updates the namespace |
| `create secret generic backend-secrets` | Creates the required namespace-local Secret |
| `--from-env-file=...` | Reads the two credential values from the private local file |
| `|| break` | Stops the loop if the preceding cluster operation fails |

Secret creation intentionally fails if the Secret exists. Identify its owner
instead of deleting or overwriting it. Prefer an existing secret manager when one
is in use. Do not duplicate its management with manual Secret creation.

**Read-only metadata check, with no credential output:**

```sh
kubectl --context local -n devops-app-stage get secret backend-secrets -o name
kubectl --context local -n devops-app-prod get secret backend-secrets -o name
```

These commands confirm existence only. They do not prove the credentials are valid
or the two environments use separate databases.

## 13. Configure Argo CD and Migrate Dev

This section describes the initial migration. If the Application already points
to an overlay and renders correctly, inspect its state rather than repeating it.

### Understand the Application configuration

The dev Application now selects:

```yaml
source:
  repoURL: https://github.com/manoharkurukuri/devops-helm.git
  targetRevision: main
  path: kustomize/overlays/dev
destination:
  server: https://kubernetes.default.svc
  namespace: devops-app
syncPolicy:
  automated:
    enabled: false
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

`repoURL` and `targetRevision` select Git, and `path` selects the overlay. The
destination server is the cluster where Argo CD is installed. There is no longer
a `source.helm` block: Argo detects Kustomize at the overlay, and the base invokes
Helm. `CreateNamespace=true` can create the namespace, not application Secrets.

The checked-in dev `enabled: false` is a migration safeguard. `prune: true` and
`selfHeal: true` do not override it. Once automation is enabled, pruning can remove
tracked resources removed from Git, and self-healing can correct live drift.
Stage/prod have no automatic sync policy and remain manual.

### Pause existing dev automation before publishing migration changes

**Cluster-changing; use during the initial migration, not as a routine check.**

```sh
kubectl --context local -n argocd patch application fullstack-dev --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

`patch` updates only the supplied fields. `--type merge` selects a JSON merge
patch, and `-p` supplies it. This disables automatic sync without deleting the
Application or workloads. Do this before publishing chart changes because the old
direct-Helm Application also follows `main`. Coordinate with any parent controller
that might restore its own Application configuration.

Review and publish the implementation using your normal Git pull-request process.
Argo CD cannot see unsaved, uncommitted, or unpushed local files. Record a known-good
revision before migrating. Do not blindly commit unrelated work or credentials.

### Enable Helm rendering in the Argo installation

The installation values contain:

```yaml
configs:
  cm:
    kustomize.buildOptions: "--enable-helm"
```

This configures `argocd-cm` through the Argo CD Helm chart. It is global to
Kustomize Applications in this Argo instance. There is no invented Application
field such as `source.kustomize.enableHelm`, and no need to disable load restrictions.

**Read-only: check the installed chart and rendering tools first.**

```sh
helm --kube-context local list -n argocd
kubectl --context local -n argocd exec deployment/argocd-repo-server -- kustomize version
kubectl --context local -n argocd exec deployment/argocd-repo-server -- helm version --short
```

`helm list` reports the installed chart version. `kubectl exec ... -- COMMAND`
executes the command inside the repo-server pod; here it only prints versions.
The inspected installation used chart `10.11.7`, Kustomize `5.8.1`, and Helm `4.2.1`.
Recheck rather than assuming these values are permanent.

**Local repository configuration plus cluster-changing Helm upgrade:**

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade argocd argo/argo-cd --kube-context local --namespace argocd \
  --version 10.11.7 --reuse-values -f bootstrap/argocd-values.yaml
kubectl --context local -n argocd get configmap argocd-cm \
  -o jsonpath='{.data.kustomize\.buildOptions}{"\n"}'
```

- `repo add` registers the official chart repository locally; `repo update`
  refreshes its chart index.
- `helm upgrade argocd argo/argo-cd` updates the existing Argo installation.
  Preserve the actually installed chart version; the example pins the observed
  version to avoid an incidental platform upgrade.
- `--reuse-values` keeps existing release values, with the supplied values file
  overriding matching keys. Review the change before executing it.
- `get configmap ... jsonpath` reads only the build-options setting. The escaped
  dot selects the literal key `kustomize.buildOptions`; expect `--enable-helm`.

Do not apply the Argo Helm values file as a Kubernetes manifest. If the setting
is correct but rendering still uses old settings, a repo-server restart may be
needed. Treat that as a deliberate platform operation, not a first troubleshooting step.

### Open the UI and obtain the initial login password

**Local port-forward; leave the command running in its terminal.**

```sh
kubectl --context local -n argocd port-forward service/argocd-server 8081:80
```

This forwards local port `8081` to Service port `80` over the Kubernetes connection.
Open `http://localhost:8081` and use username `admin`. Keep the default loopback
binding; do not expose this HTTP admin endpoint using `--address 0.0.0.0`.
Ctrl+C stops the forwarding process; it does not stop Argo CD.

**Sensitive local output: run in a separate private terminal on macOS.**

```sh
kubectl --context local -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -D; printf '\n'
```

The JSONPath selects the encoded password. macOS `base64 -D` decodes it; `printf`
adds a newline. Linux commonly uses `base64 --decode` instead. This is the initial
password, not a recovery command for a password already changed. The initial
Secret may have been removed after setup. Never share the output.

## 14. Create Applications and Manually Sync

**Creating an Application is not the same as syncing its workloads.** This caused
the earlier `Deployment not found` and `Certificate not found` errors: the
Application and namespace existed, but its first manual sync had not run.

```mermaid
flowchart TD
    FILE[Application manifest in repository] --> APPLY[Apply Application to argocd namespace]
    APPLY --> FETCH[Argo fetches Git and renders overlay]
    FETCH --> COMPARE[Compare desired resources with cluster]
    COMPARE --> MISSING[OutOfSync and Missing before first deployment]
    MISSING --> REVIEW[Review diff and prerequisites]
    REVIEW --> SYNC[Manual sync without pruning]
    SYNC --> CREATE[Resources are created]
    CREATE --> READY[Wait for workloads, certificates, and routes]
    READY --> TEST[Smoke-test application and data isolation]
```

### Apply each Application in deployment order

**Validation only:**

```sh
kubectl --context local apply --dry-run=server -f bootstrap/argocd-application.yaml
```

This validates the dev Application against the API server without storing it.
It does not validate all the resources the Application will later render.

**Cluster-changing: apply dev, then stage, then prod at the appropriate checkpoints.**

```sh
kubectl --context local apply -f bootstrap/argocd-application.yaml
kubectl --context local apply -f bootstrap/argocd-application-stage.yaml
kubectl --context local apply -f bootstrap/argocd-application-prod.yaml
```

Each command creates or updates an Application object in namespace `argocd`.
Apply/sync/verify dev before proceeding to stage, and smoke-test stage before prod.
The three commands are listed together for reference, not as an instruction to
skip those checkpoints. Existing application Secrets must already be prepared.

### Inspect the Application before sync

**Read-only; stage example:**

```sh
application=fullstack-stage
kubectl --context local -n argocd get application "$application" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl --context local -n argocd get application "$application" \
  -o jsonpath='{.status.conditions}{"\n"}{range .status.resources[*]}{.kind}{"\t"}{.namespace}{"\t"}{.name}{"\n"}{end}'
```

The first command prints concise sync/health status. The second prints rendering
conditions and resource identities. Confirm stage resources target only
`devops-app-stage`. A comparison/rendering error must be fixed before syncing.

### Option A: sync in the UI

Open the Application, refresh it, inspect **Diff**, choose **Sync**, leave **Prune**
unchecked for the initial rollout, and start the operation. Wait for success and
then verify readiness. A refresh updates comparison information; it is not a sync.

### Option B: request a sync using kubectl

This uses the installed Application CRD, so no separate Argo CLI is required.
First review the exact revision and resource diff in the UI. Do not run while
another operation is active.

**Cluster-changing; stage example pinned to its compared Git revision:**

```sh
application=fullstack-stage
revision=$(kubectl --context local -n argocd get application "$application" \
  -o jsonpath='{.status.sync.revision}')
printf 'Reviewing %s at %s\n' "$application" "$revision"
```

This block only reads and prints the revision. `$()` captures command output.
After confirming that it is the revision whose diff you reviewed, request sync:

```sh
sync_patch=$(ruby -rjson -e '
  revision = ARGV.fetch(0)
  abort "Expected a Git commit SHA" unless revision.match?(/\A[0-9a-f]{40,64}\z/)
  puts JSON.generate(operation: {sync: {revision: revision, prune: false}})
' "$revision") &&
kubectl --context local -n argocd patch application "$application" \
  --type merge -p "$sync_patch"
kubectl --context local -n argocd wait \
  --for=jsonpath='{.status.operationState.phase}'=Succeeded \
  application/"$application" --timeout=120s
```

- Ruby's JSON library builds a correctly escaped patch and rejects a missing or
  malformed revision. This avoids hand-counting nested JSON braces.
- `operation.sync.revision` pins this operation to the reviewed commit instead of
  allowing a newly advanced `main` to be selected accidentally.
- `prune: false` avoids deletion during this sync. It does not prevent updates to
  resources already owned by the Application.
- `patch` requests an Argo CD operation; the controller performs the deployment.
- `wait` watches for the operation phase `Succeeded`. On a timeout, inspect the
  operation message and UI; do not assume waiting longer fixes a failed sync.
  For subsequent syncs, also confirm the operation's revision/timestamps, because
  a prior successful operation may briefly remain visible before the new one starts.

For prod, repeat the read/review/sync process with `application=fullstack-prod`
only after stage smoke tests pass. Do not merely reuse stage's shell variables.

To inspect an operation without changing it:

```sh
kubectl --context local -n argocd get application "$application" \
  -o jsonpath='{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}{.status.operationState.syncResult.revision}{"\n"}'
```

The fields show the phase, diagnostic message, and revision processed by the
operation. They distinguish deployment failure from resources not yet becoming healthy.

After dev migration is verified, change its checked-in `automated.enabled` to
`true`, review/publish the change, and reapply that Application manifest. A Git
change to the Application file does not update the Application object unless a
separate bootstrap manager is configured to manage it. Keep stage/prod manual.

## 15. Verify Workloads, Routing, and HTTPS

**Read-only waiting and inspection, after a successful sync:**

```sh
namespace=devops-app-stage
kubectl --context local -n "$namespace" rollout status deployment/fullstack-backend --timeout=120s
kubectl --context local -n "$namespace" rollout status deployment/fullstack-frontend --timeout=120s
kubectl --context local -n "$namespace" get deployments,pods,gateways,httproutes,certificates
kubectl --context local -n "$namespace" wait --for=condition=Ready \
  certificate/notes-app-certificate --timeout=120s
kubectl --context local -n "$namespace" wait --for=condition=Programmed \
  gateway/fullstack-gateway --timeout=120s
kubectl --context local -n "$namespace" get httproute fullstack-route \
  -o jsonpath='{range .status.parents[*]}{.parentRef.sectionName}{": "}{range .conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

| Command | Explanation |
| --- | --- |
| `namespace=devops-app-stage` | Sets the namespace used by the following commands |
| Backend `rollout status` | Waits for the backend Deployment's current rollout to complete |
| Frontend `rollout status` | Does the equivalent for the frontend |
| `get deployments,pods,...` | Lists workload and routing/certificate status together |
| Certificate `wait` | Waits for cert-manager to report the application certificate Ready |
| Gateway `wait` | Waits for the Gateway controller to report it Programmed |
| HTTPRoute JSONPath | Prints each listener's route conditions; expect Accepted and ResolvedRefs to be True |

For prod, set `namespace=devops-app-prod`; for dev, use `devops-app`. These
commands never create missing workloads. `NotFound` means you must inspect the
Application, rendering, namespace, and sync operation first.

### Inspect and trust the correct local CA

**Reads a public certificate into a local file; does not expose the CA private key.**

```sh
namespace=devops-app-stage
https_port=31819
kubectl --context local -n "$namespace" get secret notes-local-ca-key \
  -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A > "/tmp/${namespace}-ca.crt"
openssl x509 -in "/tmp/${namespace}-ca.crt" -noout -subject -issuer -fingerprint -sha256
curl --cacert "/tmp/${namespace}-ca.crt" "https://192.168.252.13:${https_port}/"
```

The JSONPath selects only `tls.crt`, not `tls.key`. `openssl base64 -d -A` decodes
the Kubernetes Secret's encoded public certificate. `openssl x509` prints its
identity and SHA-256 fingerprint without dumping the certificate. Verify these
against the intended environment before trusting the CA.

`curl --cacert` trusts this CA for that request and still verifies the endpoint
certificate. It does not install system-wide trust. For browser use on macOS,
import the verified CA certificate through Keychain Access and deliberately set
the appropriate trust; each environment has its own CA. Do not import private keys.

Use prod namespace with `https_port=31820`, or dev with `https_port=31818`.
Do not use `curl -k` or bypass browser warnings as evidence that TLS is correct.

### Application smoke tests

Open the corresponding HTTPS URL and verify login plus notes create/read/update/
delete. Check browser network requests use the same environment's API port.
Verify stage data is not visible in prod and credentials/JWTs are not shared.
Infrastructure readiness alone does not establish those properties.

Cookies are not isolated by port. If this app uses cookies for authentication,
test with separate browser profiles, or move to separate hostnames before relying
on browser isolation. If the node IP changes, update every overlay API URL, the
shared default, and certificate IP SANs together.

## 16. Promote Images and Roll Back

### Promotion is an explicit Git change

```mermaid
flowchart LR
    CODE[Application code change] --> CI[Build and publish immutable images]
    CI --> TAGS[CI updates dev image-tag inputs]
    TAGS --> DEV[Sync and test dev]
    DEV --> PR1[Review PR pinning tested pair in stage]
    PR1 --> STAGE[Manual stage sync and smoke test]
    STAGE --> PR2[Review PR pinning same pair in prod]
    PR2 --> PROD[Manual prod sync and smoke test]
```

1. Existing CI updates the dev backend/frontend tag files. Do not move those
   inputs without coordinating with their writer workflow.
2. Test the resulting dev frontend/backend image pair.
3. Edit both stage image pins to that exact pair, preferably using verified digests.
4. Run the tests, review/publish the change, inspect Argo's diff, and manually sync stage.
5. Smoke-test stage before promoting the same pair to prod through another review.

Do not rebuild an image merely because it moves to another environment. Avoid
mutable `latest` tags; run-number tags also require registry no-overwrite discipline.

**Local inspection and validation before publishing a promotion:**

```sh
git diff -- kustomize/overlays/stage/kustomization.yaml
ruby test/kustomize_test.rb
```

`git diff -- PATH` shows local unstaged edits to the selected overlay; `--`
separates the path from options. The Ruby command checks the edited configuration
and verifies that future dev tag changes do not alter stage/prod output. Publish
through the repository's normal review process; no automatic commit/push is implied.

**Important boundary:** shared chart/default changes can affect all environments'
desired manifests even when images are pinned. Manual stage/prod sync prevents
automatic deployment, not comparison drift. This design does not pin an entirely
different chart revision per environment.

### Rollback restores Git's desired state

```mermaid
flowchart LR
    ISSUE[Regression detected] --> IDENTIFY[Identify affected overlay and good image pair]
    IDENTIFY --> REVERT[Review a Git revert or corrective overlay edit]
    REVERT --> BUILD[Build and test]
    BUILD --> REVIEW[Inspect Argo diff]
    REVIEW --> SYNC[Sync affected environment]
    SYNC --> VERIFY[Verify workloads and application behavior]
```

For an image regression, restore the previous tested pins in the affected
overlay, review/publish, and sync. For a shared chart regression, assess all
environments before reverting the shared change. Keep namespaces, databases,
Secrets, and certificates unless their removal is explicitly intended.

Database schema changes may need a separate compatibility/recovery plan: reverting
an image does not undo database writes. Avoid relying solely on Argo history
rollback while Git still describes the broken change; reconciliation can restore it.

## 17. What CI Validates

The existing [validation workflow](.github/workflows/helm-check.yml) now runs for
changes to the chart, root entrypoint, overlays, bootstrap configuration, tests,
or the workflow itself. A documentation-only change does not trigger those path
filters. Manual workflow dispatch is also available.

```mermaid
flowchart TD
    CHANGE[Relevant push or pull request] --> MATRIX[Helm version matrix]
    MATRIX --> H3[Helm 3.19.0]
    MATRIX --> H4[Helm 4.2.1]
    H3 --> TOOLS[Kustomize 5.8.1 and Ruby 3.3.8]
    H4 --> TOOLS
    TOOLS --> LINT[Helm lint and direct rendering]
    LINT --> RENDER[Render all Kustomize overlays]
    RENDER --> ASSERT[Validate identities, namespaces, images, ports, and references]
    ASSERT --> MUTATE[Mutation tests in temporary copies]
    MUTATE --> PASS[Pass or block the change]
```

| CI command or setting | Why it exists |
| --- | --- |
| `set -euo pipefail` | Fails the install step on command errors, unset variables, and failed pipelines |
| `mkdir -p` and `cd` in the install step | Uses a temporary runner directory, not the repository |
| `curl --fail --silent --show-error --location` | Downloads release files, follows redirects, and fails on HTTP errors |
| `sha256sum --check --ignore-missing checksums.txt` | Checks the downloaded archive against the published checksum entry |
| `tar -xzf ... kustomize` | Extracts the executable from the verified compressed archive |
| Appending the tool directory to `$GITHUB_PATH` | Makes it available to subsequent Actions steps |
| `helm lint ... --strict` | Retains default/dev chart validation |
| `helm template ... --set gateway.enabled=false` | Retains coverage for the chart's gateway-disabled rendering path |
| `ruby test/kustomize_test.rb` | Runs structured assertions on all environments and mutation scenarios |

The tests cover resource identity, namespaces, Service selectors, ConfigMap and
Secret references, image pins, routes, certificate SANs, unique NodePorts, and
Argo sources. Temporary-copy tests change dev tags and prove stage/prod manifests
stay unchanged; endpoint mutation tests prove frontend pod templates change.

A checksum detects corrupted or mismatched downloads; it is not an independent
signature verification when both files come from the same release source.
CI rendering cannot prove a database is reachable, NodePorts are free in the live
cluster, registry credentials work, or browser trust has been installed.

## 18. Troubleshooting and Everyday Workflow

### Diagnose before repeating commands

```mermaid
flowchart TD
    START[Resource or application problem] --> EXISTS{Argo Application exists?}
    EXISTS -->|No| APPLY[Review and apply Application manifest]
    EXISTS -->|Yes| RENDER{Argo can render the overlay?}
    RENDER -->|No| CONFIG[Check source path, Git revision, versions, and Helm flag]
    RENDER -->|Yes| SYNCED{Resources have been synced?}
    SYNCED -->|No| SYNC[Review diff and manually sync]
    SYNCED -->|Yes| PODS{Pods ready?}
    PODS -->|No| EVENTS[Check events, images, Secrets, and capacity]
    PODS -->|Yes| ROUTE{Gateway and TLS ready?}
    ROUTE -->|No| EDGE[Check controller conditions, ports, certificates, and CA trust]
    ROUTE -->|Yes| APP[Test login, API requests, and database isolation]
```

| Symptom | Likely explanation and next check |
| --- | --- |
| `no repo specified for pull` | Local chart directory lookup is wrong; check base chartHome and chart name |
| `must specify --enable-helm` | Missing local flag or Argo CD build option |
| `cycle detected` | An overlay is referring to an ancestor directory as its base |
| `found character that cannot start any token` | Check YAML indentation for tabs; use spaces |
| ConfigMap merge target missing | Check generator/resource name and namespace alignment |
| Resources rendered into dev namespace for stage | Check fixed Helm namespace, explicit template namespaces, and Kustomize version |
| Deployments or certificates `NotFound` | The Application may not have synced, or you selected the wrong namespace |
| `OutOfSync / Missing` with no render error | Initial manual sync may still be pending |
| `CreateContainerConfigError` | Check namespace-local Secret existence and required key names |
| `ImagePullBackOff` | Check registry access and whether the pinned image exists |
| Pods Pending | Check node capacity, requests, and scheduling events |
| Gateway not Programmed | Check controller health, GatewayClass, and NodePort conflicts |
| TLS certificate Ready but browser rejects it | Check IP SAN and trust the correct environment CA |
| Frontend still calls old endpoint | Inspect ConfigMap, replacement annotation, rollout, and browser network requests |
| Argo ignores a local edit | Publish the change to the configured repository and revision, then refresh |
| `invalid JSON patch` | Use a JSON serializer or validate braces/types before submitting the operation |

**Read-only diagnosis for workload startup failures:**

```sh
namespace=devops-app-stage
kubectl --context local -n "$namespace" get pods
kubectl --context local -n "$namespace" describe deployment fullstack-backend
kubectl --context local -n "$namespace" get events --sort-by=.metadata.creationTimestamp
kubectl --context local -n "$namespace" logs deployment/fullstack-backend --tail=100
```

`get pods` gives status and restart counts. `describe deployment` shows conditions
and deployment events. `get events --sort-by` orders events by creation time.
`logs --tail=100` shows the most recent container messages without streaming
indefinitely. Logs may contain connection details or sensitive data: inspect them
privately and redact before sharing. Add pod-specific inspection when there are
multiple replicas or an individual pod is failing.

### Short daily checklist

1. Edit shared settings or the intended environment overlay, not live workloads.
2. Build the target overlay and run the regression tests.
3. Review the Git diff, then publish through the normal review process.
4. Refresh Argo CD and review the exact desired change.
5. Sync manually where required; verify resources and application behavior.
6. Promote a tested image pair deliberately, or revert through Git when needed.

The central distinction is: **build creates YAML; applying an Application creates
the deployment definition in Argo CD; syncing creates or updates its workloads;
readiness checks and smoke tests verify the result.**

## Further Reading

- [Kubernetes: Declarative Management Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [Argo CD: Kustomize Integration](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/)
- [Argo CD: Automated Sync Policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [Repository Quick Runbook](README.md)