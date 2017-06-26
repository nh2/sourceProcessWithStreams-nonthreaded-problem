#!/usr/bin/env bash
set -eo pipefail

echo "Running with stack (runghc), this should work:\n"

stack sourceProcessWithStreams-nonthreaded-problem.hs


echo "Running compiled program (without -threaded runtime), that unfortunatley fails:\n"

stack --resolver lts-8.12 exec -- ghc --make -O sourceProcessWithStreams-nonthreaded-problem.hs
./sourceProcessWithStreams-nonthreaded-problem
