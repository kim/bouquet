.PHONY: default clean configure deps distclean install

CABAL := cabal-dev
RESOURCE_POOL := cabal-dev/packages/resource-pool/0.3.0/resource-pool-0.3.0.tar.gz

default: dist/build/*.a

install: configure
	$(CABAL) install -j

clean:
	$(CABAL) clean

configure: $(RESOURCE_POOL)
	$(CABAL) configure --verbose=2

deps: configure
	$(CABAL) install --only-dependencies -j

distclean: clean
	rm -rf cabal-dev

dist/build/*.a: deps configure
	$(CABAL) build --verbose=2

$(RESOURCE_POOL):
	$(CABAL) add-source vendor/pool
