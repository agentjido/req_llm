#!/usr/bin/env bash

export TIDEWAVE_REPL=true
export TIDEWAVE_PORT="${TIDEWAVE_PORT:-10001}"

iex -S mix
