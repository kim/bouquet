.PHONY: default build clean configure deps distclean install

CABAL := cabal-dev
RESOURCE_POOL := cabal-dev/packages/resource-pool/0.3.0/resource-pool-0.3.0.tar.gz

default: build

build: deps configure
	$(CABAL) build

install: configure
	$(CABAL) install -j

clean:
	$(CABAL) clean

configure: $(RESOURCE_POOL)
	$(CABAL) configure --verbose=2

deps: $(RESOURCE_POOL)
	$(CABAL) install --only-dependencies -j

distclean: clean
	rm -rf cabal-dev

$(RESOURCE_POOL):
	$(CABAL) add-source vendor/pool
