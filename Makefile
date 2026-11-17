f1discord: *.mbt stub.c moon.mod moon.pkg
	moon build --target native --release
	cp _build/native/release/build/f1discord.exe $@.new && mv $@.new $@

clean:
	moon clean
	rm -f f1discord

.PHONY: clean
