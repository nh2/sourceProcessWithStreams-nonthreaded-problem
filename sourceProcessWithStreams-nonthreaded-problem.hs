#!/usr/bin/env stack
-- stack --resolver lts-8.12 script

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}

import           Control.Concurrent (forkIOWithUnmask, threadWaitRead)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad.IO.Class
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Process hiding (sourceProcessWithStreams, streamingProcess)
import           Data.Maybe (fromMaybe)
import           Data.Streaming.Process.Internal
import           Say
import           System.Exit
import           System.IO (hClose)
import           System.Posix.IO (closeFd)
import           System.Posix.Types (Fd(Fd))
import qualified System.Process.Internals        as PI

streamingProcess :: (MonadIO m, InputSource stdin, OutputSink stdout, OutputSink stderr)
               => CreateProcess
               -> m (stdin, stdout, stderr, StreamingProcessHandle)
streamingProcess cp = liftIO $ do
    let (getStdin, stdinStream) = isStdStream
        (getStdout, stdoutStream) = osStdStream
        (getStderr, stderrStream) = osStdStream

    -- We use a pipe to the child process to determine when it's dead.
    -- In Unix, when there is a Unix pipe between two processes, then
    --   "When the child process terminates, its end of the pipe will be closed"
    -- (see https://stackoverflow.com/questions/8976004/using-waitpid-or-sigaction/8976461#8976461)
    -- See also http://tldp.org/LDP/lpg/node11.html about Unix pipes.
    -- Making this decision based on a pipe FD is better than `waitpid()` because
    -- we can use GHC IO manager's `threadWaitRead` function to wait in a
    -- non-blocking, non-polling way.
    (readFd, writeFd) <- ((\(r,w) -> (Fd r, Fd w))) <$> createPipeFd

    (stdinH, stdoutH, stderrH, ph) <- PI.createProcess_ "streamingProcess" cp
        { std_in = fromMaybe (std_in cp) stdinStream
        , std_out = fromMaybe (std_out cp) stdoutStream
        , std_err = fromMaybe (std_err cp) stderrStream
        }

    -- Close pipe write end from parent process (we don't need it).
    closeFd writeFd
    -- When the child process closes its write end (e.g. by terminating),
    -- we'll read EOF on our read end, and we wait for that to happen with
    -- the `threadWaitRead readFd` below.

    ec <- atomically newEmptyTMVar
    -- Apparently waitForProcess can throw an exception itself when
    -- delegate_ctlc is True, so to avoid this TMVar from being left empty, we
    -- capture any exceptions and store them as an impure exception in the
    -- TMVar
    _ <- forkIOWithUnmask $ \_unmask -> try (threadWaitRead readFd >> waitForProcess ph)
        >>= atomically
          . putTMVar ec
          . either
              (throw :: SomeException -> a)
              id

    let close =
            mclose stdinH `finally` mclose stdoutH `finally` mclose stderrH
          where
            mclose = maybe (return ()) hClose

    (,,,)
        <$> getStdin stdinH
        <*> getStdout stdoutH
        <*> getStderr stderrH
        <*> return (StreamingProcessHandle ph ec close)

terminateStreamingProcess :: StreamingProcessHandle -> IO ()
terminateStreamingProcess = terminateProcess . streamingProcessHandleRaw

sourceProcessWithStreams :: CreateProcess
                         -> Producer IO ByteString   -- ^stdin
                         -> Consumer ByteString IO a -- ^stdout
                         -> Consumer ByteString IO b -- ^stderr
                         -> IO (ExitCode, a, b)
sourceProcessWithStreams cp producerStdin consumerStdout consumerStderr = do
  putStrLn "BEFORE STREAMING PROCESS"
  (  (sinkStdin, closeStdin)
   , (sourceStdout, closeStdout)
   , (sourceStderr, closeStderr)
   , sph) <- streamingProcess cp
  liftIO (say "AFTER STREAMING PROCESS")
  (_, resStdout, resStderr) <-
    runConcurrently (
      (,,)
      <$> Concurrently (say "STDIN" >> ((producerStdin $$ sinkStdin) `finally` (say "FINALLY 1" >> closeStdin)))
      <*> Concurrently (say "STDOUT" >> (sourceStdout  $$ consumerStdout))
      <*> Concurrently (say "STDERR" >> (sourceStderr  $$ consumerStderr)))
    `finally` (say "FINALLY" >> closeStdout >> closeStderr)
    `onException` (say "TERMINATE" >> terminateStreamingProcess sph)
  ec <- waitForStreamingProcess sph
  return (ec, resStdout, resStderr)

main :: IO ()
main = do
  (exitCode, stdout, stderr) <- sourceProcessWithStreams
    (shell $ "sleep 1; yes | head --bytes=" ++ show (65536 + 1 :: Int)) -- 65536 == Linux pipe; buffer size; one byte more and it hangs
    (return ()) -- stdin
    (CL.consume) -- stdout
    (CL.consume) -- stderr

  print (exitCode, sum (map BS.length stdout), sum (map BS.length stderr))
