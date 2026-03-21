.PHONY: build release clean

build:
	crystal build src/enable.cr -o bin/enable

release:
	crystal build src/enable.cr -o bin/enable --release --no-debug

clean:
	rm -f bin/enable
