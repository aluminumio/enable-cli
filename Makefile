.PHONY: build release clean

build:
	mkdir -p bin
	crystal build src/enable.cr -o bin/enbl

release:
	mkdir -p bin
	crystal build src/enable.cr -o bin/enbl --release --no-debug

clean:
	rm -f bin/enbl
