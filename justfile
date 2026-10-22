# Consent Ledger task runner
# Run `just` to see all available commands

set dotenv-load := true

default:
    @just --list

fmt:
    forge fmt

fmt-check:
    forge fmt --check

lint:
    solhint 'src/**/*.sol' 'test/**/*.sol' 'script/**/*.sol' --max-warnings 0

forge-lint:
    forge lint --deny warnings src

# Requires slither: `pip install slither-analyzer`
slither:
    slither . --config-file slither.config.json --fail-medium

test:
    forge test -vvv

build:
    forge build --build-info --sizes src

clean:
    forge clean

gas:
    forge test --gas-report

coverage:
    forge coverage --report summary

gen-abis:
    ./generate-abis.sh

# Fails if abis/ is out of date with the contracts
check-abis: gen-abis
    @test -z "$(git status --porcelain -- abis)" || (git status --short -- abis && echo "ABIs are out of date: run 'just gen-abis' and commit abis/" && exit 1)

# CI equivalent check
check: fmt-check lint forge-lint test build slither check-abis
    @echo "All checks passed."

pre-push: fmt-check lint forge-lint test check-abis
    @echo "Ready to push."

fix: fmt lint test
    @echo "Fixed and validated."
