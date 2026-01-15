.PHONY: fmt

# Format all nix files in the project
fmt:
	nixfmt flake.nix
