# Repro: `sourceProcessWithStreams` hangs without `-threaded` runtime

Demonstrates issue that [`sourceProcessWithStreams`](https://www.stackage.org/haddock/lts-8.20/conduit-extra-1.1.16/src/Data.Conduit.Process.html#sourceProcessWithStreams) from `conduit-extra-1.1.16` doesn't work without `-threaded` runtime.

To reproduce, run `./test.sh`.


## Explanation

I found a problem with `sourceProcessWithStreams` from `conduit-extra`.
It hangs without `-threaded`. (I'm running without `-threaded` to check for some potential bug when OS threads are involved.)

I think I know what the problem is:

The [`streamingProcess`](https://github.com/fpco/streaming-commons/blob/276be069fc130f2457a667ade56343ea8e9492ac/Data/Streaming/Process.hs#L166) that it calls from `streaming-commons` does:

```haskell
    _ <- forkIOWithUnmask $ \_unmask -> try (waitForProcess ph)
        >>= atomically
          . putTMVar ec
          . either
              (throw :: SomeException -> a)
              id

    -- return afterwards here
```

So it returns only after calling `waitForProcess`.
In the non-threaded runtime, `waitForProcess` (syscall `wait()`) means Haskell stops running.

There is also a race involved: Sometimes it works.
That happens when the code that does the actual pipe data shuffling (in `sourceProcessWithStreams`) has enough time to finish between the `forkIOWithUnmask` and the actual `waitForProcess` invocation (thus the `sleep 1` in my repro to make it always happen).

And of course it happens only if the output produced by the spawned program is larger than the OS pipe buffer (64K on Linux). Otherwise the program writes into the pipe buffer, exits, `wait()` returns and the bug does not appear.
