# Self Node Remediation - Automatic Kubernetes Node Remediation 
<p align="center">
<img width="200" src="config/assets/snr_icon_blue.png">
</p>

Existing baremetal remediation strategies utilize BMC credentials to power-cycle and/or reprovision the host.
However there are also environments that either do not include BMCs, or there are policies
in place that prevent them from being utilized.  Such environments would also benefit from
the ability to safely recover affected workloads and restore cluster capacity (where possible).
This self node remediation controller is using an alternate mechanism for a node in a cluster to detect its health
status and take actions to remediate itself in case of a failure.  While not all remediation events can
result in the node returning to a healthy state, the proposal does allow surviving parts of the cluster
to assume the node has reached a safe state so that it’s workloads can be automatically recovered.
This work can also be useful for clusters with BMC credentials.


## Packaging

> **This is the `wao` branch.** It differs from `main` in packaging only; the controller source is
> unchanged.

This branch builds **only the controller container**, as a plain kubebuilder project, in the same
way [oadp-non-admin](https://github.com/migtools/oadp-non-admin) does. There is no OLM bundle, no
catalog and no ClusterServiceVersion here.

The [Workload Availability Operator](https://github.com/medik8s/workload-availability-operator)
(WAO) owns the packaging: it ships the CRDs and the operand RBAC in its own CSV, and deploys this
controller as one of its operands. SNR is no longer installed as a standalone operator.

What this branch removed: `bundle/`, `bundle.Dockerfile`, `config/manifests/` (CSV base),
`config/scorecard/`, and every `bundle-*`, `catalog-*`, `operator-sdk` and `opm` Make target.

What it keeps, and why:

| Path | Why WAO needs it |
| --- | --- |
| `cmd/`, `api/`, `internal/` | the controller itself |
| `config/crd/bases` | `controller-gen` output; WAO ships these CRDs |
| `config/rbac` | `controller-gen` output from the `//+kubebuilder:rbac:` markers. **This is generated from the controller source and must stay here** — it is the only place that knows what permissions the code requires, and WAO derives its CSV rules from it |
| `config/{default,manager,webhook,certmanager,samples,prometheus}` | a working `make deploy` without OLM |
| `install/` | the agent DaemonSet and NetworkPolicy templates the config controller renders at runtime from inside the image |

### Build and deploy

```sh
make docker-build docker-push IMG=<registry>/self-node-remediation-operator:<tag>
make deploy IMG=<registry>/self-node-remediation-operator:<tag>   # plain kustomize, no OLM
make undeploy
```

### Known gaps on this branch

- `.github/workflows/kind-e2e.yaml` and `hack/local-run.sh` still install SNR through OLM and will
  fail here. They need rewriting against `make deploy` or moving to WAO.
- The shared `dev-olm-*` and `dev-bundle-run` targets come from
  [medik8s/tools](https://github.com/medik8s/tools) `dev/dev.mk` and no longer apply; the other
  `dev-*` targets are unaffected.

## More Info
https://www.medik8s.io/

## Project State
Self Node Remediation works best together with [Node Health Check Operator](https://operatorhub.io/operator/node-healthcheck-operator)

## Help
Feel free to join our google group to get more info - https://groups.google.com/g/medik8s
