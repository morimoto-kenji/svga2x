NASM ?= nasm

bin/SVGA2X.COM: src/svga2x.asm
	mkdir -p bin
	$(NASM) -f bin -o $@ -l bin/svga2x.lst $<

clean:
	rm -rf bin

.PHONY: clean
