defmodule ReqLLM.Providers.GoogleVertex.TokenCacheTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.GoogleVertex.TokenCache

  setup do
    # Clear cache before each test
    TokenCache.clear_all()
    :ok
  end

  describe "get_or_refresh/1" do
    test "caches ADC tokens by default source" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      token_fetcher = fn :adc, _opts ->
        Agent.update(counter, &(&1 + 1))

        {:ok,
         %{
           token: "adc-token",
           expires_at: System.system_time(:second) + 3600
         }}
      end

      assert {:ok, "adc-token"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)
      assert {:ok, "adc-token"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)
      assert Agent.get(counter, & &1) == 1
    end

    test "refreshes expired ADC tokens" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      token_fetcher = fn :adc, _opts ->
        count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        {:ok,
         %{
           token: "adc-token-#{count}",
           expires_at: System.system_time(:second) - 1
         }}
      end

      assert {:ok, "adc-token-1"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)
      assert {:ok, "adc-token-2"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)
      assert Agent.get(counter, & &1) == 2
    end

    test "scopes ADC cache by GOOGLE_APPLICATION_CREDENTIALS so credential swaps refresh" do
      env_snapshot = System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

      on_exit(fn ->
        case env_snapshot do
          nil -> System.delete_env("GOOGLE_APPLICATION_CREDENTIALS")
          value -> System.put_env("GOOGLE_APPLICATION_CREDENTIALS", value)
        end
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      token_fetcher = fn :adc, _opts ->
        count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        {:ok,
         %{
           token: "adc-token-#{count}",
           expires_at: System.system_time(:second) + 3600
         }}
      end

      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/adc-credentials-a.json")
      assert {:ok, "adc-token-1"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)
      assert {:ok, "adc-token-1"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)

      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/adc-credentials-b.json")
      assert {:ok, "adc-token-2"} = TokenCache.get_or_refresh(:adc, token_fetcher: token_fetcher)

      assert Agent.get(counter, & &1) == 2
    end

    @tag :skip
    test "fetches token on first call" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      assert {:ok, token} = TokenCache.get_or_refresh(service_account_path)
      assert is_binary(token)
      assert String.starts_with?(token, "ya29.")
    end

    @tag :skip
    test "returns cached token on subsequent calls within TTL" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      {:ok, token1} = TokenCache.get_or_refresh(service_account_path)
      {:ok, token2} = TokenCache.get_or_refresh(service_account_path)

      # Same token should be returned from cache
      assert token1 == token2
    end

    test "handles file not found error" do
      result = TokenCache.get_or_refresh("/nonexistent/service-account.json")
      assert {:error, _reason} = result
    end

    test "handles invalid JSON error" do
      # Create a temp file with invalid JSON
      temp_path = Path.join(System.tmp_dir!(), "invalid.json")
      File.write!(temp_path, "not valid json")

      result = TokenCache.get_or_refresh(temp_path)
      assert {:error, _reason} = result

      File.rm!(temp_path)
    end

    test "handles JSON string with invalid JSON" do
      # JSON string that starts with { but is invalid
      json_string = ~s({"client_email": "test@example.com", invalid})

      result = TokenCache.get_or_refresh(json_string)
      assert {:error, _reason} = result
    end

    test "handles JSON string with valid JSON but no private_key" do
      # Valid JSON but missing required fields for auth
      json_string = ~s({"client_email": "test@example.com"})

      result = TokenCache.get_or_refresh(json_string)
      # Will fail in JWT signing since no private_key
      assert {:error, _reason} = result
    end

    test "handles map with missing private_key" do
      # Map missing required fields for auth
      map = %{"client_email" => "test@example.com"}

      result = TokenCache.get_or_refresh(map)
      # Will fail in JWT signing since no private_key
      assert {:error, _reason} = result
    end

    test "handles map with atom keys" do
      # Users might pass atom keys instead of string keys
      map = %{client_email: "test@example.com"}

      result = TokenCache.get_or_refresh(map)
      # Should normalize keys and fail in JWT signing (no private_key)
      assert {:error, _reason} = result
    end

    test "parses JSON string when not a file path" do
      # Non-existent file path that is valid JSON gets parsed as JSON
      json_string = ~s({"client_email": "test@example.com"})

      result = TokenCache.get_or_refresh(json_string)
      # Should parse as JSON and fail (no private_key)
      assert {:error, _reason} = result
    end

    test "returns clear error for invalid credentials string" do
      # Not a file, not valid JSON
      result = TokenCache.get_or_refresh("not-a-file-and-not-json")

      assert {:error, reason} = result
      assert reason =~ "Invalid service account credentials"
      assert reason =~ "not a valid file path or JSON string"
    end

    @tag :skip
    test "fetches token with JSON string credentials" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      json_content = File.read!(service_account_path)

      assert {:ok, token} = TokenCache.get_or_refresh(json_content)
      assert is_binary(token)
      assert String.starts_with?(token, "ya29.")
    end

    @tag :skip
    test "fetches token with map credentials" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      {:ok, map} = service_account_path |> File.read!() |> Jason.decode()

      assert {:ok, token} = TokenCache.get_or_refresh(map)
      assert is_binary(token)
      assert String.starts_with?(token, "ya29.")
    end

    @tag :skip
    test "fetches token with map using atom keys" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      {:ok, string_map} = service_account_path |> File.read!() |> Jason.decode()

      # Convert to atom keys
      atom_map = Map.new(string_map, fn {k, v} -> {String.to_atom(k), v} end)

      assert {:ok, token} = TokenCache.get_or_refresh(atom_map)
      assert is_binary(token)
      assert String.starts_with?(token, "ya29.")
    end

    @tag :skip
    test "uses client_email as cache key for JSON string" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      json_content = File.read!(service_account_path)
      {:ok, parsed} = Jason.decode(json_content)
      client_email = parsed["client_email"]

      # First call - fetches token
      {:ok, token1} = TokenCache.get_or_refresh(json_content)

      # Invalidate by client_email (the cache key for JSON strings)
      :ok = TokenCache.invalidate(client_email)

      # Second call - should fetch new token (cache was invalidated)
      {:ok, token2} = TokenCache.get_or_refresh(json_content)

      # Both should be valid tokens
      assert is_binary(token1)
      assert is_binary(token2)
    end
  end

  describe "invalidate/1" do
    test "removes cached token by file path" do
      # This is a unit test, so we can't actually verify token behavior
      # but we can verify the invalidate function doesn't crash
      assert :ok = TokenCache.invalidate("/some/path.json")
    end

    test "removes cached token by client_email" do
      # For inline JSON credentials, client_email is the cache key
      assert :ok = TokenCache.invalidate("test@example.iam.gserviceaccount.com")
    end

    @tag :skip
    test "next call fetches fresh token after invalidation" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      {:ok, _token1} = TokenCache.get_or_refresh(service_account_path)

      # Invalidate the cache
      :ok = TokenCache.invalidate(service_account_path)

      # Next call should fetch a new token
      {:ok, token2} = TokenCache.get_or_refresh(service_account_path)

      # Note: In practice tokens might be the same if fetched quickly,
      # but the important thing is that it made a new request
      assert is_binary(token2)
    end
  end

  describe "clear_all/0" do
    test "removes all cached tokens" do
      # Verify clear_all doesn't crash
      assert :ok = TokenCache.clear_all()
    end

    @tag :skip
    test "all subsequent calls fetch fresh tokens after clear" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")
      assert service_account_path, "GOOGLE_SERVICE_ACCOUNT_JSON env var required"
      assert File.exists?(service_account_path), "File not found: #{service_account_path}"

      {:ok, _token1} = TokenCache.get_or_refresh(service_account_path)

      # Clear all cache
      :ok = TokenCache.clear_all()

      # Next call should fetch a new token
      {:ok, token2} = TokenCache.get_or_refresh(service_account_path)
      assert is_binary(token2)
    end
  end

  describe "concurrent requests" do
    test "handles concurrent requests without crashing" do
      # Spawn multiple concurrent requests
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            # Use an invalid path so we get consistent errors
            TokenCache.get_or_refresh("/nonexistent.json")
          end)
        end

      results = Task.await_many(tasks)

      # All should return errors
      assert Enum.all?(results, fn result -> match?({:error, _}, result) end)
    end
  end

  describe "cache key behavior" do
    test "file path uses path as cache key" do
      # Create a temp file with valid JSON structure but invalid key
      # (so it fails at JWT signing, not parsing)
      temp_path = Path.join(System.tmp_dir!(), "test_service_account.json")
      json = Jason.encode!(%{"client_email" => "test@example.com", "private_key" => "invalid"})
      File.write!(temp_path, json)

      # First call - will fail at JWT signing
      {:error, _} = TokenCache.get_or_refresh(temp_path)

      # Verify we can invalidate by file path
      assert :ok = TokenCache.invalidate(temp_path)

      File.rm!(temp_path)
    end

    test "JSON string uses client_email as cache key" do
      json = ~s({"client_email": "cache-test@example.com", "private_key": "invalid"})

      # First call - will fail at JWT signing
      {:error, _} = TokenCache.get_or_refresh(json)

      # Should be able to invalidate by client_email (not the JSON string)
      assert :ok = TokenCache.invalidate("cache-test@example.com")
    end

    test "map uses client_email as cache key" do
      map = %{"client_email" => "map-test@example.com", "private_key" => "invalid"}

      # First call - will fail at JWT signing
      {:error, _} = TokenCache.get_or_refresh(map)

      # Should be able to invalidate by client_email
      assert :ok = TokenCache.invalidate("map-test@example.com")
    end

    test "map with atom keys normalizes to string keys" do
      map = %{client_email: "atom-test@example.com", private_key: "invalid"}

      # First call - will fail at JWT signing
      {:error, _} = TokenCache.get_or_refresh(map)

      # Should be able to invalidate by client_email (string)
      assert :ok = TokenCache.invalidate("atom-test@example.com")
    end
  end
end
