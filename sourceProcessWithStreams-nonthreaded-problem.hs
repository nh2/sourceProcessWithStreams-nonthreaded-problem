#!/usr/bin/env stack
-- stack --resolver lts-8.12 script

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}

import           Control.Concurrent.Async
import           Control.Exception (finally, onException)
import           Control.Monad.IO.Class
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Conduit
import qualified Data.Conduit.List as CL
import           Data.Conduit.Process hiding (sourceProcessWithStreams)
import           Say
import           System.Exit

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
      <$> Concurrently (say "STDIN" >> ((producerStdin $$ sinkStdin) `finally` closeStdin))
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
