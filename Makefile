SHELL_BITS=files/dupwrap.sh

test:
	for bit in $(SHELL_BITS) ; do \
	    docker run -v "$(shell pwd)/$$bit:/tmp/FileToBeChecked" chrisdaish/shellcheck ; \
	done
	yamllint tasks/*.yml defaults/*.yml meta/*.yml
