# Chart maintenance targets.
#
#   make docs          - regenerate per-chart README.md via helm-docs.
#   make docs-check    - fail if the committed READMEs are stale (CI target).
#   make lint          - helm lint every subchart.
#   make dep-update    - rebuild charts/*.tgz for the umbrella.
#   make dep-check     - fail if charts/*.tgz are missing or stale (CI target).
#   make template      - render the umbrella across the supported feature matrix.
#
# Install helm-docs once:
#   go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest

CHART_ROOT := charts/openldap-platform
SUBCHARTS  := $(CHART_ROOT)/charts

.PHONY: docs docs-check lint dep-update dep-check template

docs:
	helm-docs --chart-search-root=$(CHART_ROOT) --skip-version-footer

docs-check:
	@tmp=$$(mktemp -d) && \
	  cp -R $(CHART_ROOT) $$tmp/ && \
	  helm-docs --chart-search-root=$$tmp/openldap-platform --skip-version-footer >/dev/null && \
	  diff -qr $(CHART_ROOT) $$tmp/openldap-platform || \
	  { echo 'ERROR: chart READMEs out of date - run `make docs`'; exit 1; }
	@echo 'READMEs up to date.'

lint:
	@for chart in $(SUBCHARTS)/*/; do \
	  helm lint $$chart || exit 1; \
	done
	@helm lint $(CHART_ROOT)

# The file:// dependencies are packaged into $(SUBCHARTS)/*.tgz, and Helm
# PREFERS those archives over the sibling source directories. A stale archive
# therefore silently shadows every edit made to charts/<name>/ - `helm template`
# and `helm install` both render the packaged copy. Wipe before rebuilding so a
# renamed or removed subchart cannot leave an orphan archive behind either.
dep-update:
	rm -f $(SUBCHARTS)/*.tgz
	helm dependency update $(CHART_ROOT)

# Guard for the above: fail when an archive is missing, or older than any file
# in its own source tree. Run it before lint/template/package so nobody ever
# validates or ships the shadowed copy.
dep-check:
	@rc=0; \
	for src in $(SUBCHARTS)/*/; do \
	  name=$$(basename $$src); \
	  ver=$$(awk '/^version:/ {print $$2; exit}' $$src/Chart.yaml); \
	  tgz=$(SUBCHARTS)/$$name-$$ver.tgz; \
	  if [ ! -f "$$tgz" ]; then \
	    echo "ERROR: $$tgz missing - run \`make dep-update\`"; rc=1; continue; \
	  fi; \
	  if [ -n "$$(find $$src -newer $$tgz -print -quit)" ]; then \
	    echo "ERROR: $$tgz is older than $$src - run \`make dep-update\`"; rc=1; \
	  fi; \
	done; \
	for tgz in $(SUBCHARTS)/*.tgz; do \
	  [ -e "$$tgz" ] || continue; \
	  base=$$(basename $$tgz .tgz); \
	  name=$${base%-*}; ver=$${base##*-}; \
	  src=$(SUBCHARTS)/$$name; \
	  if [ ! -d "$$src" ]; then \
	    echo "ERROR: $$tgz has no source directory - run \`make dep-update\`"; rc=1; continue; \
	  fi; \
	  cur=$$(awk '/^version:/ {print $$2; exit}' $$src/Chart.yaml); \
	  if [ "$$ver" != "$$cur" ]; then \
	    echo "ERROR: $$tgz shadows $$src (Chart.yaml is at $$cur) - run \`make dep-update\`"; rc=1; \
	  fi; \
	done; \
	[ $$rc -eq 0 ] && echo 'Packaged subcharts match their sources.'; \
	exit $$rc

template: dep-check
	@helm template test $(CHART_ROOT) >/dev/null && echo 'Umbrella renders.'
