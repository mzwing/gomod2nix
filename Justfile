nix_sources := "git ls-files '*.nix'"
shell_sources := "git ls-files '*.sh'"

default: lint

# Static checks. What needs a build or a sandbox lives in the flake instead, under `nix flake check`.
lint: lint-nix lint-nix-types lint-actions lint-shell

# Format in place.
fmt:
    {{ nix_sources }} | xargs alejandra
    {{ shell_sources }} | xargs shfmt --write

lint-nix:
    {{ nix_sources }} | xargs alejandra --check

lint-nix-types:
    typenix --noEmit

lint-actions:
    actionlint

lint-shell:
    {{ shell_sources }} | xargs shfmt --diff
    {{ shell_sources }} | xargs shellcheck
