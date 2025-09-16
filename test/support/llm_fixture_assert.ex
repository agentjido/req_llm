defmodule LLMFixture.Assert do
  @moduledoc """
  Assertion helpers for validating Context.Codec encoding and option translation
  in LLM fixture files.
  """

  import ExUnit.Assertions

  @doc """
  Assert that the canonical JSON in a fixture matches the expected Context encoding.

  This validates that ReqLLM.Context.encode_request/2 produces the expected result
  for a given context and model combination.

  ## Options

    * `:ignore` - List of keys to ignore in comparison (default: [])

  ## Examples

      import ReqLLM.Context
      
      context = Context.new([
        system("You are helpful"),
        user("Hello")
      ])
      
      LLMFixture.Assert.assert_encoded(:anthropic, "test_fixture", context, 
                                      "anthropic:claude-3-haiku-20240307")
  """
  def assert_encoded(provider, fixture_name, context, model, opts \\ []) do
    %{"request" => %{"canonical_json" => recorded}} = load_fixture(provider, fixture_name)
    expected = ReqLLM.Context.encode_request(context, model) |> normalize_for_comparison()
    recorded_normalized = recorded |> normalize_for_comparison() |> scrub(opts)
    expected_scrubbed = expected |> scrub(opts)

    assert recorded_normalized == expected_scrubbed,
           """
           Context encoding mismatch:
           Expected: #{inspect(expected_scrubbed, pretty: true)}
           Recorded: #{inspect(recorded_normalized, pretty: true)}
           """
  end

  @doc """
  Assert that specific options are correctly translated in the fixture's canonical JSON.

  Takes a function that receives the recorded canonical JSON and returns true/false
  or raises an assertion failure.

  ## Examples

      LLMFixture.Assert.assert_options(:anthropic, "test_fixture", fn json ->
        json["max_tokens"] == 100 and json["temperature"] == 0.5
      end)
  """
  def assert_options(provider, fixture_name, assertion_fn) when is_function(assertion_fn, 1) do
    %{"request" => %{"canonical_json" => recorded}} = load_fixture(provider, fixture_name)

    assert assertion_fn.(recorded),
           "Option assertion failed for #{provider}/#{fixture_name}. Recorded JSON: #{inspect(recorded, pretty: true)}"
  end

  @doc """
  Assert that the HTTP request method and URL match expectations.
  """
  def assert_request(provider, fixture_name, expected_method, expected_url) do
    %{"request" => request} = load_fixture(provider, fixture_name)

    assert String.upcase(to_string(request["method"])) ==
             String.upcase(to_string(expected_method)),
           "Expected method #{expected_method}, got #{request["method"]}"

    assert request["url"] == expected_url,
           "Expected URL #{expected_url}, got #{request["url"]}"
  end

  @doc """
  Assert that the response has expected status and content type.
  """
  def assert_response(
        provider,
        fixture_name,
        expected_status,
        expected_content_type \\ "application/json"
      ) do
    %{"response" => response} = load_fixture(provider, fixture_name)

    assert response["status"] == expected_status,
           "Expected status #{expected_status}, got #{response["status"]}"

    content_types = List.wrap(response["headers"]["content-type"] || [])

    assert Enum.any?(content_types, &String.contains?(&1, expected_content_type)),
           "Expected content-type containing #{expected_content_type}, got #{inspect(content_types)}"
  end

  # Private helpers

  defp load_fixture(provider, fixture_name) do
    path = fixture_path(provider, fixture_name)

    if !File.exists?(path) do
      raise """
      Fixture not found: #{path}
      Run the test with LIVE=true to capture it first.
      """
    end

    path |> File.read!() |> Jason.decode!()
  end

  defp fixture_path(provider, name) do
    Path.join([__DIR__, "fixtures", to_string(provider), "#{name}.json"])
  end

  defp normalize_for_comparison(data) do
    # Convert atom keys to string keys and ensure consistent format
    case data do
      map when is_map(map) ->
        map
        |> Map.new(fn {k, v} -> {to_string(k), normalize_for_comparison(v)} end)

      list when is_list(list) ->
        Enum.map(list, &normalize_for_comparison/1)

      other ->
        other
    end
  end

  defp scrub(json, opts) do
    ignore_keys = Keyword.get(opts, :ignore, [])

    case json do
      map when is_map(map) -> Map.drop(map, ignore_keys)
      other -> other
    end
  end
end
