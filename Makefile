SHELLCHECK_SCRIPTS = files/dupwrap.sh files/swap_helper.sh

.PHONY: lint shellcheck test test-ubuntu2204 test-ubuntu2404 test-debian12 test-debian13 test-all test-e2e-local test-e2e-s3 clean distclean

VENV := .venv
BIN := $(VENV)/bin
export PATH := $(CURDIR)/$(BIN):$(PATH)

$(VENV): requirements-dev.txt
	python3 -m venv $(VENV)
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -r requirements-dev.txt
	@touch $(VENV)

shellcheck:
	@had_error=0; \
	for script in $(SHELLCHECK_SCRIPTS); do \
		echo "(shell) Checking $$script"; \
		docker run -t --rm \
			-v "$(shell pwd)/$$script:/mnt/$$script" \
			"koalaman/shellcheck-alpine:stable" \
			"shellcheck" -S warning "/mnt/$$script" || had_error=1; \
	done; \
	if [ $$had_error -eq 1 ]; then \
		exit 1; \
	fi

lint: $(VENV) shellcheck
	$(BIN)/yamllint -c .yamllint defaults tasks vars meta
	$(BIN)/ansible-lint

test: lint test-all test-e2e-local

test-ubuntu2204: $(VENV)
	MOLECULE_DISTRO=ubuntu2204 $(BIN)/molecule test

test-ubuntu2404: $(VENV)
	MOLECULE_DISTRO=ubuntu2404 $(BIN)/molecule test

test-debian12: $(VENV)
	MOLECULE_DISTRO=debian12 $(BIN)/molecule test

test-debian13: $(VENV)
	MOLECULE_DISTRO=debian13 $(BIN)/molecule test

test-all: test-ubuntu2204 test-ubuntu2404 test-debian12 test-debian13

test-e2e-local: $(VENV)
	MOLECULE_DISTRO=ubuntu2404 $(BIN)/molecule test -s e2e-local

test-e2e-s3: $(VENV)
	bash tests/run-e2e-s3.sh

clean:
	$(BIN)/molecule destroy 2>/dev/null || true

distclean: clean
	rm -rf $(VENV)
