.PHONY: dev test install

dev:            ## Servidor local con reload en :8000
	./scripts/dev.sh

test:           ## Smoke test de los endpoints
	./scripts/smoke-test.sh

install:        ## Instalar en AlmaLinux 10 (requiere sudo)
	sudo ./install.sh
