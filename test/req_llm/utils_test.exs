defmodule ReqLLM.UtilsTest.MockProviderWithSchema do
  @moduledoc false

  def provider_schema do
    %NimbleOptions{
      schema: [
        temperature: [type: :float, default: 0.7, doc: "Sampling temperature"],
        max_tokens: [type: :pos_integer, doc: "Maximum tokens to generate"]
      ]
    }
  end
end

defmodule ReqLLM.UtilsTest.MockProviderWithoutSchema do
  @moduledoc false
  # This module intentionally has no provider_schema/0 function
end

defmodule ReqLLM.UtilsTest do
  use ExUnit.Case, async: true


  alias ReqLLM.Utils
  alias ReqLLM.UtilsTest.MockProviderWithoutSchema
  alias ReqLLM.UtilsTest.MockProviderWithSchema

  describe "merge_req_options/2" do
    test "returns request unchanged for falsy req_options" do
      request = %Req.Request{url: "http://example.com"}

      for {opts, desc} <- [
            {[req_options: []], "empty list"},
            {[req_options: nil], "nil"},
            {[req_options: %{}], "empty map"},
            {[other_option: "value"], "missing key"}
          ] do
        result = Utils.merge_req_options(request, opts)
        assert result == request, "Failed for #{desc}: #{inspect(opts)}"
      end
    end

    test "merges req_options for map and keyword list" do
      request = %Req.Request{url: "http://example.com"}
      request = Req.Request.register_options(request, [:custom_option])

      for req_opts <- [%{custom_option: "test"}, [custom_option: "test"]] do
        opts = [req_options: req_opts]
        result = Utils.merge_req_options(request, opts)

        assert %Req.Request{} = result
        refute result == request
      end
    end
  end



  describe "compose_schema/2" do
    setup do
      base_schema = %NimbleOptions{
        schema: [
          model: [type: :string, required: true],
          provider_options: [type: :keyword_list, default: []]
        ]
      }

      %{base_schema: base_schema}
    end

    test "returns base schema unchanged when provider has no schema function", %{
      base_schema: base_schema
    } do
      result = ReqLLM.Provider.Options.compose_schema(base_schema, MockProviderWithoutSchema)
      assert result == base_schema
    end

    test "composes schema when provider has schema function", %{base_schema: base_schema} do
      result = ReqLLM.Provider.Options.compose_schema(base_schema, MockProviderWithSchema)

      assert %NimbleOptions{} = result
      provider_options = Keyword.get(result.schema, :provider_options)
      keys = Keyword.get(provider_options, :keys)

      assert Keyword.get(provider_options, :type) == :keyword_list
      assert Keyword.get(provider_options, :default) == []
      assert Keyword.has_key?(keys, :temperature)
      assert Keyword.has_key?(keys, :max_tokens)
    end

    test "validates composed schema correctly", %{base_schema: base_schema} do
      composed = ReqLLM.Provider.Options.compose_schema(base_schema, MockProviderWithSchema)

      # Valid options should pass
      assert {:ok, _result} =
               NimbleOptions.validate(
                 [
                   model: "test-model",
                   provider_options: [temperature: 0.8, max_tokens: 100]
                 ],
                 composed
               )

      # Invalid options should fail
      assert {:error, _reason} =
               NimbleOptions.validate(
                 [
                   model: "test-model",
                   provider_options: [temperature: "invalid"]
                 ],
                 composed
               )
    end

    test "raises KeyError for invalid base schema" do
      invalid_schema = %NimbleOptions{schema: [model: [type: :string, required: true]]}

      assert_raise KeyError, fn ->
        ReqLLM.Provider.Options.compose_schema(invalid_schema, MockProviderWithSchema)
      end

      assert_raise KeyError, fn ->
        ReqLLM.Provider.Options.compose_schema(nil, MockProviderWithSchema)
      end
    end
  end
end
