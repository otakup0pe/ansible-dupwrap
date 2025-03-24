SHELL_BITS = $(wildcard files/*.sh)

test:
	@$(foreach script,$(SHELL_BITS),docker run -t --rm \
			-v "$(shell pwd)/$(script):/mnt/$(script)" \
			"koalaman/shellcheck-alpine:stable" \
			"shellcheck" "/mnt/$(script)" || exit;)
	yamllint tasks/*.yml defaults/*.yml meta/*.yml
