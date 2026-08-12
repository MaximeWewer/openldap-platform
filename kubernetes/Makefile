# Chart maintenance targets.
#
#   make docs          - regenerate per-chart README.md via helm-docs.
#   make docs-check    - fail if the committed READMEs are stale (CI target).
#   make lint          - helm lint every subchart.
#   make dep-update    - refresh charts/*.tgz for the umbrella (needed
#                        after touching a subchart's Chart.yaml version).
#
# Install helm-docs once:
#   go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest

CHART_ROOT := charts/openldap-platform

.PHONY: docs docs-check lint dep-update

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
	@for chart in $(CHART_ROOT)/charts/*/; do \
	  helm lint $$chart || exit 1; \
	done
	@helm lint $(CHART_ROOT)

dep-update:
	helm dependency update $(CHART_ROOT)
