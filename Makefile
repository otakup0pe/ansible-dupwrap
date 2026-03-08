.PHONY: lint test test-ubuntu2204 test-ubuntu2404 test-debian12 test-debian13 test-all clean distclean

VENV := .venv
BIN := $(VENV)/bin
export PATH := $(CURDIR)/$(BIN):$(PATH)

$(VENV): requirements-dev.txt
	python3 -m venv $(VENV)
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -r requirements-dev.txt
	@touch $(VENV)

lint: $(VENV)
	$(BIN)/yamllint -c .yamllint defaults tasks vars meta
	$(BIN)/ansible-lint -c .ansible-lint defaults tasks vars meta

test: lint test-all

test-ubuntu2204: $(VENV)
	MOLECULE_DISTRO=ubuntu2204 $(BIN)/molecule test

test-ubuntu2404: $(VENV)
	MOLECULE_DISTRO=ubuntu2404 $(BIN)/molecule test

test-debian12: $(VENV)
	MOLECULE_DISTRO=debian12 $(BIN)/molecule test

test-debian13: $(VENV)
	MOLECULE_DISTRO=debian13 $(BIN)/molecule test

test-all: test-ubuntu2204 test-ubuntu2404 test-debian12 test-debian13

clean:
	$(BIN)/molecule destroy 2>/dev/null || true

distclean: clean
	rm -rf $(VENV)
