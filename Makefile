MAKEFILE_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(MAKEFILE_DIR)/standard_defs.mk

export OPENSSL_STATIC=1

ARCH_TYPE ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

HOST_ARCHITECTURE ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
CHRONICLE_BUILDER_IMAGE ?= blockchaintp/chronicle-builder-$(ARCH_TYPE)
CHRONICLE_TP_IMAGE ?= blockchaintp/chronicle-tp-$(ARCH_TYPE)
CHRONICLE_VERSION ?= BTP2.1.0-0.6.0

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1


CLEAN_DIRS := $(CLEAN_DIRS)

DOMAINS := $(shell find . -mindepth 3 -maxdepth 3 -name domain.yaml \
	-exec dirname {} \; | awk -F/ '{print $$NF}')

distclean: clean_docker clean_markers

$(MARKERS):
	mkdir -p $(MARKERS)

DOCKER_COMPOSE := docker-compose
DOCKER_BUILD := docker buildx build
DOCKER_TAG := docker tag

.PHONY: clean_docker
clean_docker: clean
	docker buildx rm ctx-$(ISOLATION_ID) || true

define domain_tmpl =
.PHONY: all-domains
all-domains: $(1)

.PHONY: inmem
inmem: $(1)-inmem

.PHONY: stl
stl: $(1)-stl

$(1): $(1)-inmem $(1)-sdl $(1)-sdl $(1)-diagrams

$(1)-inmem: $(1)-inmem $(1)-inmem-release

$(1)-stl: $(1)-stl $(1)-stl-release

$(1)-diagrams:
ifeq (,$(shell command -v plantuml))
	@echo "Skipping $(1) diagrams, no plantuml"
else
	@echo "Building $(1) diagrams"
	$(foreach DIAGRAM,$(wildcard domains/$(1)/diagrams/*.puml),plantuml -tsvg -nometadata "$(DIAGRAM)";)
endif

.PHONY: $(1)-lint
$(1)-lint:
	@echo "Checking domain definition for $(1)"
	@docker run --volume $(shell pwd)/domains/$(1):/mnt \
	            --entrypoint /usr/local/bin/chronicle-domain-lint --rm \
	            $(CHRONICLE_BUILDER_IMAGE):$(CHRONICLE_VERSION) /mnt/domain.yaml

.PHONY: $(MARKERS)/ensure-context-$(1)
$(MARKERS)/ensure-context-$(1): $(MARKERS)
	docker buildx create --name ctx-$(ISOLATION_ID) \
		--driver docker-container \
		--driver-opt network=host \
		--bootstrap || true
	docker buildx use ctx-$(ISOLATION_ID)
	touch $(MARKERS)/ensure-context-$(1)

.PHONY: ($1)-inmem
$(1)-inmem: $(MARKERS)/ensure-context-$(1) domains/$(1)/domain.yaml $(1)-lint
	@echo "Building $(1) debug inmem as docker image chronicle-$(1)-inmem:$(ISOLATION_ID)"
	$(DOCKER_BUILD) -f docker/chronicle.dockerfile \
		--builder ctx-$(ISOLATION_ID) \
		--tag chronicle-domain:$(ISOLATION_ID) \
		--build-arg CHRONICLE_VERSION=$(CHRONICLE_VERSION) \
		--build-arg CHRONICLE_BUILDER_IMAGE=$(CHRONICLE_BUILDER_IMAGE) \
		--build-arg RELEASE=no \
		--build-arg FEATURES=inmem \
		--build-arg DOMAIN=$(1) . \
		--load
	@$(DOCKER_TAG) chronicle-domain:$(ISOLATION_ID) \
		chronicle-$(1)-inmem:$(ISOLATION_ID)

.PHONY: $(1)-stl
$(1)-stl:$(MARKERS)/ensure-context-$(1) domains/$(1)/domain.yaml $(1)-lint
	@echo "Building $(1) debug chronicle stl as docker image as docker image chronicle-$(1)-stl:$(ISOLATION_ID)"
	@$(DOCKER_BUILD) -f docker/chronicle.dockerfile \
		--builder ctx-$(ISOLATION_ID) \
		--tag chronicle-domain:$(ISOLATION_ID) \
		--build-arg CHRONICLE_VERSION=$(CHRONICLE_VERSION) \
		--build-arg CHRONICLE_BUILDER_IMAGE=$(CHRONICLE_BUILDER_IMAGE) \
		--build-arg RELEASE=no \
		--build-arg FEATURES="" \
		--build-arg DOMAIN=$(1) . \
		--load
	@$(DOCKER_TAG) chronicle-domain:$(ISOLATION_ID) \
		chronicle-$(1)-stl:$(ISOLATION_ID)

.PHONY: $(1)-inmem-release
$(1)-inmem-release: $(MARKERS)/ensure-context-$(1) domains/$(1)/domain.yaml $(1)-lint
	@echo "Building $(1) release inmem as docker image chronicle-$(1)-inmem-release:$(ISOLATION_ID)"
	@$(DOCKER_BUILD) -f docker/chronicle.dockerfile \
		--builder ctx-$(ISOLATION_ID) \
		--tag chronicle-domain:$(ISOLATION_ID) \
		--build-arg CHRONICLE_VERSION=$(CHRONICLE_VERSION) \
		--build-arg CHRONICLE_BUILDER_IMAGE=$(CHRONICLE_BUILDER_IMAGE) \
		--build-arg RELEASE=yes \
		--build-arg FEATURES="inmem" \
		--build-arg DOMAIN=$(1) . \
		--load
	@$(DOCKER_TAG) chronicle-domain:$(ISOLATION_ID) \
		chronicle-$(1)-inmem-release:$(ISOLATION_ID)

.PHONY: $(1)-stl-release
$(1)-stl-release: $(MARKERS)/ensure-context-$(1) domains/$(1)/domain.yaml $(1)-lint
	@echo "Building $(1) release chronicle stl  as docker image chronicle-$(1)-stl-release:$(ISOLATION_ID)"
	@$(DOCKER_BUILD) -f docker/chronicle.dockerfile \
		--builder ctx-$(ISOLATION_ID) \
		--tag chronicle-domain:$(ISOLATION_ID) \
		--build-arg CHRONICLE_VERSION=$(CHRONICLE_VERSION) \
		--build-arg CHRONICLE_BUILDER_IMAGE=$(CHRONICLE_BUILDER_IMAGE) \
		--build-arg RELEASE=yes \
		--build-arg FEATURES="" \
		--build-arg DOMAIN=$(1) . \
		--load
	@$(DOCKER_TAG) chronicle-domain:$(ISOLATION_ID) \
		chronicle-$(1)-stl-release:$(ISOLATION_ID)

domains/$(1)/chronicle.graphql: $(1)-inmem
	@echo "Generating $(1) GraphQL schema in file: domains/$(1)/chronicle.graphql"
	@docker run --env RUST_LOG=debug chronicle-$(1)-inmem:$(ISOLATION_ID) \
		export-schema > domains/$(1)/chronicle.graphql

.PHONY: clean-graphql-$(1)
clean-graphql-$(1):
	rm -f domains/$(1)/chronicle.graphql

.PHONY: $(1)-sdl
$(1)-sdl: domains/$(1)/chronicle.graphql

.PHONY: run-$(1)
run-$(1): $(1)-inmem
	docker run -it -e RUST_LOG=debug -p 9982:9982 --rm \
		chronicle-$(1)-inmem:$(ISOLATION_ID) \
			--console-logging pretty \
			--embedded-database \
			serve-graphql --interface 0.0.0.0:9982 --open

.PHONY: run-stl-$(1)
run-stl-$(1): $(1)-stl
	export CHRONICLE_IMAGE=chronicle-$(1)-stl; \
	export CHRONICLE_TP_IMAGE=$(CHRONICLE_TP_IMAGE); \
	export CHRONICLE_VERSION=$(ISOLATION_ID); \
	export CHRONICLE_TP_VERSION=$(CHRONICLE_VERSION); \
	$(DOCKER_COMPOSE) -f docker/chronicle.yaml up --force-recreate -d

.PHONY: stop-stl-$(1)
stop-stl-$(1): $(1)-stl
	export CHRONICLE_IMAGE=chronicle-$(1)-stl; \
	export CHRONICLE_TP_IMAGE=$(CHRONICLE_TP_IMAGE); \
	export CHRONICLE_VERSION=$(ISOLATION_ID); \
	export CHRONICLE_TP_VERSION=$(CHRONICLE_VERSION); \
	$(DOCKER_COMPOSE) -f docker/chronicle.yaml down

.PHONY: build-end-to-end-test
build-end-to-end-test:
	docker build -t chronicle-test:$(ISOLATION_ID) -f docker/chronicle-test/chronicle-test.dockerfile .

.PHONY: test-e2e
test-e2e: build-end-to-end-test
	COMPOSE_PROFILES=test CHRONICLE_IMAGE=chronicle-evidence-stl CHRONICLE_VERSION=$(ISOLATION_ID) \
	 $(COMPOSE) -f docker/chronicle.yaml up --exit-code-from chronicle-test

.PHONY: clean-images-$(1)
clean-images-$(1): $(MARKERS)
	docker buildx rm ctx-$(ISOLATION_ID) || true
	docker rmi chronicle-$(1)-inmem:$(ISOLATION_ID) || true
	docker rmi chronicle-$(1)-inmem-release:$(ISOLATION_ID) || true
	docker rmi chronicle-$(1)-stl:$(ISOLATION_ID) || true
	docker rmi chronicle-$(1)-stl-release:$(ISOLATION_ID) || true
	docker rmi chronicle-test$(ISOLATION_ID) || true
	rm -f $(MARKERS)/*-$(1)

clean-$(1): clean-images-$(1) clean-graphql-$(1)

clean: clean-$(1)

endef

test:


$(foreach domain,$(DOMAINS),$(eval $(call domain_tmpl,$(domain))))

.PHONY: sdl
sdl: $(foreach domain,$(DOMAINS), $(domain)-sdl )

.PHONY: build
build: sdl
