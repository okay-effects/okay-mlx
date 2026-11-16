#!/bin/bash
# stall.sh PORT MODEL: request A streams up to 2500 tokens; 2 s in, request B sends a long new prompt (~9k tokens).
# A's largest gap between pieces while B is read, and B's time to its first token.
PORT=${1:-8090}; MODEL=${2:-mlx-community/Qwen3.5-4B-MLX-4bit}; S=$(mktemp -d)
BIG=$(for i in $(seq 1 700); do printf 'line %d: the quick brown fox jumps over the lazy dog. ' $i; done)
ts() { perl -MTime::HiRes=time -ne 'BEGIN{$|=1} printf "%.3f %s", time, $_'; }
body() { printf '{"model":"%s","stream":true,"messages":[{"role":"user","content":"%s"}],"max_tokens":%d,"chat_template_kwargs":{"enable_thinking":false}}' "$MODEL" "$1" "$2"; }
curl -sN localhost:$PORT/v1/chat/completions -H 'content-type: application/json' \
  -d "$(body 'Write a very long story about a lighthouse keeper, in twenty chapters.' 2500)" | ts > $S/a.txt &
A=$!
sleep 2
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
curl -sN localhost:$PORT/v1/chat/completions -H 'content-type: application/json' \
  -d "$(body "Run $RANDOM$RANDOM. Count the lines. $BIG" 20)" | ts > $S/b.txt
t1=$(grep '"content":"[^"]' $S/b.txt | head -1 | awk '{print $1}')
wait $A
grep '"content":"[^"]' $S/a.txt | awk -v t0=$t0 -v t1=$t1 '$1>=t0 && $1<=t1+1 {if(p) {g=($1-p)*1000; if(g>m)m=g} p=$1; n++} END{printf "A max gap while B read %.0f ms (%d pieces); ", m, n}'
awk -v t0=$t0 -v t1=$t1 'BEGIN{printf "B first token after %.0f ms\n", (t1-t0)*1000}'
