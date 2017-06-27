#!/usr/bin/env stack
-- stack --resolver lts-8.12 script

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}

import           Control.Applicative ((<|>))
import           Control.Concurrent (forkIOWithUnmask)
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
import           Data.Streaming.Process hiding (streamingProcess)
import           Data.Streaming.Process.Internal
import           GHC.Conc.IO (threadWaitRead, threadWaitWrite)
import           Say
import           System.Exit
import           System.IO (hClose)
import qualified System.Process.Internals        as PI

import           Data.Typeable (cast)
import qualified GHC.IO.Device as IODevice
import           GHC.IO.Handle.Internals
import           GHC.IO.Handle.Types
import           GHC.IO.FD (FD(fdFD))
import           System.Posix.Types (Fd(Fd))

streamingProcess :: (MonadIO m, InputSource stdin, OutputSink stdout, OutputSink stderr)
               => CreateProcess
               -> m (stdin, stdout, stderr, StreamingProcessHandle)
streamingProcess cp = liftIO $ do
    let (getStdin, stdinStream) = isStdStream
        (getStdout, stdoutStream) = osStdStream
        (getStderr, stderrStream) = osStdStream

    (stdinH, stdoutH, stderrH, ph) <- PI.createProcess_ "streamingProcess" cp
        { std_in = fromMaybe (std_in cp) stdinStream
        , std_out = fromMaybe (std_out cp) stdoutStream
        , std_err = fromMaybe (std_err cp) stderrStream
        }

    let waitForReadHandleChanged (Just h) = do
          case h of
            DuplexHandle{} -> error "shouldn't happen"
            FileHandle _ mvar -> do
              withHandle_' "waitForReadHandleChanged" h mvar $ \Handle__{ haDevice = device, haType = haType } -> do
                case haType of
                  ClosedHandle -> return ()
                  _ ->
                    case cast device of
                      Nothing -> error "waitForReadHandleChanged: device is not an FD!"
                      Just (fd :: FD) -> do
                        threadWaitRead (Fd (fdFD fd))
                        return ()
        waitForReadHandleChanged Nothing = error "shouldn't happen"
    let waitForWriteHandleChanged (Just h) = do
          case h of
            DuplexHandle{} -> error "shouldn't happen"
            FileHandle _ mvar -> do
              withHandle_' "waitForWriteHandleChanged" h mvar $ \Handle__{ haDevice = device, haType = haType } -> do
                case haType of
                  ClosedHandle -> return ()
                  _ ->
                    case cast device of
                      Nothing -> error "waitForWriteHandleChanged: device is not an FD!"
                      Just (fd :: FD) -> do
                        threadWaitWrite (Fd (fdFD fd))
                        return ()
        waitForWriteHandleChanged Nothing = error "shouldn't happen"

    let nonblockingWaitForProcessLoop :: IO ExitCode
        nonblockingWaitForProcessLoop = do
          mExitCode <- getProcessExitCode ph
          case mExitCode of
            Just exitCode -> return exitCode
            Nothing -> do
              runConcurrently $
                    Concurrently (waitForWriteHandleChanged stdinH >> say "A")
                <|> Concurrently (waitForReadHandleChanged stdoutH >> say "B")
                <|> Concurrently (waitForReadHandleChanged stderrH >> say "C")
              nonblockingWaitForProcessLoop

    ec <- atomically newEmptyTMVar
    -- Apparently waitForProcess can throw an exception itself when
    -- delegate_ctlc is True, so to avoid this TMVar from being left empty, we
    -- capture any exceptions and store them as an impure exception in the
    -- TMVar
    _ <- forkIOWithUnmask $ \_unmask -> try nonblockingWaitForProcessLoop
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
   , (sourceStdout, closeStdout :: IO ())
   , (sourceStderr, closeStderr :: IO ())
   , sph) <- streamingProcess cp
  liftIO (say "AFTER STREAMING PROCESS")
  (_, resStdout, resStderr) <-
    runConcurrently (
      (,,)
      <$> Concurrently (say "STDIN" >> ((producerStdin $$ sinkStdin) `finally` (say "FINALLY 1" >> closeStdin)))
      <*> Concurrently (say "STDOUT" >> (sourceStdout  $$ consumerStdout))
      <*> Concurrently (say "STDERR" >> (sourceStderr  $$ consumerStderr)))
    `finally` (say "FINALLY" >> closeStdout >> closeStderr)
    -- `finally` (say "FINALLY") -- TODO close again after debugging
    `onException` (say "TERMINATE" >> terminateStreamingProcess sph)
  ec <- waitForStreamingProcess sph
  return (ec, resStdout, resStderr)

main :: IO ()
main = do
  (exitCode, stdout, stderr) <- sourceProcessWithStreams
    (shell $ "sleep 10; yes | head --bytes=" ++ show (65536 + 1 :: Int)) -- 65536 == Linux pipe; buffer size; one byte more and it hangs
    (return ()) -- stdin
    (CL.consume) -- stdout
    (CL.consume) -- stderr

  print (exitCode, sum (map BS.length stdout), sum (map BS.length stderr))
