# Repro: `sourceProcessWithStreams` hangs without `-threaded` runtime

Demonstrates issue that [`sourceProcessWithStreams`](https://www.stackage.org/haddock/lts-8.20/conduit-extra-1.1.16/src/Data.Conduit.Process.html#sourceProcessWithStreams) from `conduit-extra-1.1.16` doesn't work without `-threaded` runtime.

To reproduce, run `./test.sh`.
