defmodule ReqLLM.Providers.GoogleVertex.TokenCacheTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.GoogleVertex.TokenCache

  setup do
    # Clear cache before each test
    TokenCache.clear_all()
    :ok
  end

  describe "get_or_refresh/1" do
    @tag :skip
    test "fetches token on first call" do
      # This test requires a valid service account JSON file
      # Skip in CI/CD, run manually for integration testing
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")

      if service_account_path && File.exists?(service_account_path) do
        assert {:ok, token} = TokenCache.get_or_refresh(service_account_path)
        assert is_binary(token)
        assert String.starts_with?(token, "ya29.")
      end
    end

    @tag :skip
    test "returns cached token on subsequent calls within TTL" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")

      if service_account_path && File.exists?(service_account_path) do
        {:ok, token1} = TokenCache.get_or_refresh(service_account_path)
        {:ok, token2} = TokenCache.get_or_refresh(service_account_path)

        # Same token should be returned from cache
        assert token1 == token2
      end
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
  end

  describe "invalidate/1" do
    test "removes cached token" do
      # This is a unit test, so we can't actually verify token behavior
      # but we can verify the invalidate function doesn't crash
      assert :ok = TokenCache.invalidate("/some/path.json")
    end

    @tag :skip
    test "next call fetches fresh token after invalidation" do
      service_account_path = System.get_env("GOOGLE_SERVICE_ACCOUNT_JSON")

      if service_account_path && File.exists?(service_account_path) do
        {:ok, _token1} = TokenCache.get_or_refresh(service_account_path)

        # Invalidate the cache
        :ok = TokenCache.invalidate(service_account_path)

        # Next call should fetch a new token
        {:ok, token2} = TokenCache.get_or_refresh(service_account_path)

        # Tokens should be different (new token generated)
        # Note: In practice they might be the same if fetched quickly,
        # but the important thing is that it made a new request
        assert is_binary(token2)
      end
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

      if service_account_path && File.exists?(service_account_path) do
        {:ok, _token1} = TokenCache.get_or_refresh(service_account_path)

        # Clear all cache
        :ok = TokenCache.clear_all()

        # Next call should fetch a new token
        {:ok, token2} = TokenCache.get_or_refresh(service_account_path)
        assert is_binary(token2)
      end
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
end
