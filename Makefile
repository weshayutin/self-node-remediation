# SHELL defines bash so all the inline scripts here will work as expected.
SHELL := /bin/bash

# versions at  https://github.com/kubernetes-sigs/controller-tools/releases
CONTROLLER_GEN_VERSION =  v0.20.1

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary, align with k8s.io/client-go in go.mod
ENVTEST_K8S_VERSION = 1.34

# update for major version updates to KUSTOMIZE_VERSION!
KUSTOMIZE_API_VERSION = v5
# versions at https://github.com/kubernetes-sigs/kustomize/releases
KUSTOMIZE_VERSION = v5.8.1

# https://pkg.go.dev/sigs.k8s.io/controller-runtime/tools/setup-envtest/env?tab=versions
ENVTEST_VERSION = v0.0.0-20260120065648-aebc15d7c689

# versions at https://github.com/slintes/sort-imports/tags
SORT_IMPORTS_VERSION = v0.3.0

# version at https://github.com/a8m/envsubst/releases
ENVSUBST_VERSION = v1.4.3

# update for major version updates to YQ_VERSION! see https://github.com/mikefarah/yq
YQ_API_VERSION = v4
YQ_VERSION = v4.53.2

OPERATOR_NAME ?= self-node-remediation
OPERATOR_NAMESPACE ?= openshift-workload-availability

# VERSION is the project version, used only to tag the controller image. This repository no longer
# produces an OLM bundle or catalog: the Workload Availability Operator (WAO) owns the packaging
# and deploys the controller image built here. See README.md, "Packaging".
DEFAULT_VERSION := 5.8.0
VERSION ?= $(DEFAULT_VERSION)
export VERSION

# IMAGE_REGISTRY used to indicate the registry/group for the controller image
IMAGE_REGISTRY ?= quay.io/medik8s
export IMAGE_REGISTRY

IMAGE_TAG_BASE ?= $(IMAGE_REGISTRY)/$(OPERATOR_NAME)

# Use the selected version for image tags. Development builds can still override IMAGE_TAG.
IMAGE_TAG = v$(VERSION)
export IMAGE_TAG

# Image URL to use all building/pushing image targets
export IMG ?= $(IMAGE_TAG_BASE)-operator:$(IMAGE_TAG)

.PHONY: print-image-tag
print-image-tag: ## Print the current image tag (used by CI to know what was just built)
	@echo $(IMAGE_TAG)

# Get the currently used golang install path (in GOPATH/bin.old, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Use kubectl, fallback to oc
KUBECTL = kubectl
ifeq (,$(shell which kubectl))
KUBECTL=oc
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
CONTAINER_TOOL ?= podman
export CONTAINER_TOOL

all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen protoc ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations. Also generate protoc / gRPC code
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."
	PATH='$(PATH)':$(shell pwd)/bin/proto/bin && $(PROTOC) --go_out=. --go-grpc_out=. internal/peerhealth/peerhealth.proto

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: verify-no-changes
verify-no-changes: ## verify there are no un-staged changes
	./hack/verify-diff.sh

# CI uses a non-writable home dir, make sure .cache is writable
ifeq ("${HOME}", "/")
HOME=/tmp
endif

BIN_ASSETS_DIR=$(shell pwd)/bin
ENVTEST_ASSETS_DIR = ${BIN_ASSETS_DIR}/setup-envtest
ENVTEST = $(shell pwd)/bin/setup-envtest

# Use TEST_OPS to pass further options to `go test` (e.g. -gingo.v and/or -ginkgo.focus)
export TEST_OPS ?= ""
.PHONY: test
test: go-verify envtest generate fix-imports manifests fmt vet ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path --bin-dir $(PROJECT_DIR)/testbin)" \
		KUBEBUILDER_CONTROLPLANE_STOP_TIMEOUT="60s"\
		go test ./api/... ./cmd/... ./internal/... ./version/... -coverprofile cover.out -v ${TEST_OPS}

.PHONY: create-ns
create-ns: ## Create namespace
	$(KUBECTL) get ns $(OPERATOR_NAMESPACE) 2>&1> /dev/null || \
		($(KUBECTL) create ns $(OPERATOR_NAMESPACE) && $(MAKE) set-labels-to-namespace)

.PHONY: set-labels-to-namespace
set-labels-to-namespace: ## Set labels on NS as workaround for OLM pod not running with restricted PSA
	oc label --overwrite ns $(OPERATOR_NAMESPACE) security.openshift.io/scc.podSecurityLabelSync=false
	oc label --overwrite ns $(OPERATOR_NAMESPACE) pod-security.kubernetes.io/enforce=privileged


##@ Build

.PHONY: build
build: generate fmt vet ## Build manager binary.
	./hack/build.sh

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

.PHONY: docker-build
docker-build: test
	$(CONTAINER_TOOL) build --build-arg OPERATOR_VERSION=$(VERSION) -t ${IMG} .

.PHONY: docker-build-check
docker-build-check: check
	$(CONTAINER_TOOL) build --build-arg OPERATOR_VERSION=$(VERSION) -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

##@ Deployment

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete -f -

.PHONY: deploy
deploy: manifests kustomize envsubst ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(ENVSUBST) | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete -f -

##@ Build Dependencies

CONTROLLER_GEN_BIN_FOLDER = $(shell pwd)/bin/controller-gen
CONTROLLER_GEN = $(CONTROLLER_GEN_BIN_FOLDER)/$(CONTROLLER_GEN_VERSION)/controller-gen
.PHONY: controller-gen
controller-gen: ## Download controller-gen locally if necessary.
ifeq (,$(wildcard $(CONTROLLER_GEN)))
	@{ \
	rm -rf $(CONTROLLER_GEN_BIN_FOLDER) ;\
	mkdir -p $(dir $(CONTROLLER_GEN)) ;\
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@${CONTROLLER_GEN_VERSION}) ;\
	}
endif

ENVSUBST_BIN_FOLDER = $(shell pwd)/bin/envsubst
ENVSUBST = $(ENVSUBST_BIN_FOLDER)/$(ENVSUBST_VERSION)/envsubst
.PHONY: envsubst
envsubst: ## Download envsubst locally if necessary.
	@$(call go-install-tool,$(ENVSUBST),github.com/a8m/envsubst/cmd/envsubst@${ENVSUBST_VERSION}) ;\

KUSTOMIZE_BIN_FOLDER = $(shell pwd)/bin/kustomize
KUSTOMIZE = $(KUSTOMIZE_BIN_FOLDER)/$(KUSTOMIZE_VERSION)/kustomize
.PHONY: kustomize
kustomize: ## Download kustomize locally if necessary.
ifeq (,$(wildcard $(KUSTOMIZE)))
	@{ \
	rm -rf $(KUSTOMIZE_BIN_FOLDER) ;\
	mkdir -p $(dir $(KUSTOMIZE)) ;\
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/$(KUSTOMIZE_API_VERSION)@${KUSTOMIZE_VERSION}) ;\
	}
endif

.PHONY: envtest
envtest: ## Download envtest-setup locally if necessary.
	@$(call go-install-tool,$(ENVTEST_ASSETS_DIR),sigs.k8s.io/controller-runtime/tools/setup-envtest@$(ENVTEST_VERSION)) # no tagged versions :/

# go-install-tool will 'go install' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-install-tool
[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
BIN_DIR=$$(dirname $(1)) ;\
mkdir -p $$BIN_DIR ;\
echo "Downloading $(2)" ;\
GOBIN=$$BIN_DIR GOFLAGS='' CGO_ENABLED=0 go install $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

.PHONY: protoc
PROTOC = $(shell pwd)/bin/proto/bin/protoc
# map Go arch names to the ones used by protobuf release artifacts
PROTOC_ARCH = $(shell go env GOARCH | sed -e 's/amd64/x86_64/' -e 's/arm64/aarch_64/')
protoc: protoc-gen-go protoc-gen-go-grpc ## Download protoc (protocol buffers tool needed for gRPC)
	test -f ${PROTOC} || (cd $(shell pwd)/bin/proto && curl -sSLo protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v3.16.0/protoc-3.16.0-linux-$(PROTOC_ARCH).zip && unzip -o protoc.zip && rm protoc.zip)

.PHONY: protoc-gen-go
PROTOC_GEN_GO = $(shell pwd)/bin/proto/bin/protoc-gen-go
protoc-gen-go: ## Download protoc-gen-go locally if necessary.
	@$(call go-install-tool,$(PROTOC_GEN_GO),google.golang.org/protobuf/cmd/protoc-gen-go@v1.26)

.PHONY: protoc-gen-go-grpc
PROTOC_GEN_GO_GRPC = $(shell pwd)/bin/proto/bin/protoc-gen-go-prpc
protoc-gen-go-grpc: ## Download protoc-gen-go-grpc locally if necessary.
	@$(call go-install-tool,$(PROTOC_GEN_GO_GRPC),google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.1.0)

.PHONY: e2e-test
e2e-test:
	# KUBECONFIG must be set to the cluster, and SNR needs to be deployed already
    # count arg makes the test ignoring cached test results
	go test ./e2e -ginkgo.vv -test.v -timeout 80m -count=1 ${TEST_OPS}

YQ = $(shell pwd)/bin/yq
.PHONY: yq
yq: ## Download yq locally if necessary.
	@$(call go-install-tool,$(YQ),github.com/mikefarah/yq/$(YQ_API_VERSION)@$(YQ_VERSION))

##@ Targets used by CI

.PHONY: check
# WORKAROUND: add "protoc" as dependency for downloading binary first, the golang image misses the needed "unzip"tool
check: protoc ## Dockerized version of make test
	make test

.PHONY: container-build
container-build: docker-build ## Build the controller container


.PHONY: container-push
container-push: ## Push the controller container
	make docker-push

.PHONY: tidy
tidy: # Run go mod tidy - add missing and remove unused modules.
	go mod tidy

.PHONY: vendor
vendor: # Run go mod vendor - make vendored copy of dependencies.
	go mod vendor

.PHONY: go-verify
go-verify: tidy vendor # Run go mod verify - verify dependencies have expected content
	go mod verify

.PHONY: verify-vendor
verify-vendor: go-verify verify-no-changes ##Verifies vendor and tidy didn't cause changes

.PHONY: sort-imports
sort-imports: ## Download sort-imports locally if necessary.
	@$(call go-install-tool,$(SORT_IMPORTS),github.com/slintes/sort-imports@$(SORT_IMPORTS_VERSION))

.PHONY: test-imports
test-imports: sort-imports ## Check for sorted imports
	$(SORT_IMPORTS) .

.PHONY: fix-imports
fix-imports: sort-imports ## Sort imports
	$(SORT_IMPORTS) -w .

.PHONY: full-gen
full-gen:  tidy vendor generate manifests fix-imports ## generates all automatically generated content

# Shared dev environment
# Uses a local sibling checkout if available (e.g. ../tools),
# otherwise downloads the tools repo into .tools/ on first dev-* target use.
#
# IMPORTANT: Do NOT use $(shell git clone ...) here — $(shell) executes at
# Makefile parse time, so any make invocation (make build, make test, make help)
# would trigger a git clone. The dev-% fallback rule below is lazy: the clone
# only runs when a dev-* target is actually invoked.
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_MK := $(TOOLS_DIR)/dev/dev.mk
ifeq ($(wildcard $(DEV_MK)),)
  TOOLS_DIR := $(shell pwd)/.tools
  DEV_MK := $(TOOLS_DIR)/dev/dev.mk
endif
-include $(DEV_MK)
ifeq ($(wildcard $(DEV_MK)),)
dev-%:
	@echo "Downloading medik8s/tools into $(TOOLS_DIR)..."
	@if [ -d $(TOOLS_DIR) ]; then \
		if [ -f $(TOOLS_DIR)/.managed-by-makefile ]; then \
			echo "  Removing stale $(TOOLS_DIR)..."; rm -rf $(TOOLS_DIR); \
		else \
			echo "Error: $(TOOLS_DIR) exists but was not created by this Makefile (missing .managed-by-makefile sentinel)."; \
			echo "       Remove it manually or set TOOLS_DIR to a valid medik8s/tools checkout."; exit 1; \
		fi; \
	fi
	@git clone --depth 1 https://github.com/medik8s/tools.git $(TOOLS_DIR)
	@touch $(TOOLS_DIR)/.managed-by-makefile
	@test -f $(DEV_MK) || { echo "Error: $(DEV_MK) not found after clone."; exit 1; }
	@$(MAKE) $@
endif
