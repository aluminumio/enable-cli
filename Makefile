.PHONY: build release clean

build:
	crystal build src/enable.cr -o bin/enbl

release:
	crystal build src/enable.cr -o bin/enbl --release --no-debug

clean:
	rm -f bin/enbl
