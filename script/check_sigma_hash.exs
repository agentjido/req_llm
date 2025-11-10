# script/check_sigma_hash.exs
# Purpose: CI guard that enforces Σ receipt consistency between repo and environment.

path = System.get_env("REQLLM_VERSION_TTL") || "ontologies/reqllm.version.ttl"
env  = System.get_env("Σ_HASH") || System.get_env("SIGMA_HASH") || System.get_env("SIGMA_RECEIPT")

ttl = File.read!(path)

with [_, hash] <- Regex.run(~r/req:hash\s+"([0-9a-fA-F]+)"/, ttl) do
  cond do
    is_nil(env) ->
      IO.puts("Σ receipt found in TTL (#{hash}), but Σ_HASH env var is missing.")
      System.halt(1)

    env == hash ->
      IO.puts("OK: Σ_HASH matches (#{hash}).")
      :ok

    true ->
      IO.puts("Mismatch: Σ_HASH=#{env}, TTL=#{hash}")
      System.halt(2)
  end
else
  _ ->
    IO.puts("Could not find req:hash in #{path}")
    System.halt(3)
end
