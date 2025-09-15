defmodule ReqLLM.Provider.DSL do
  @moduledoc """
  Domain-Specific Language for defining ReqLLM providers.

  This macro simplifies provider creation by automatically handling:
  - Plugin behaviour implementation
  - Metadata loading from JSON files
  - Provider registry registration
  - Default configuration setup

  ## Usage

      defmodule MyProvider do
      use ReqLLM.Provider.DSL,
      id: :my_provider,
      base_url: "https://api.example.com/v1",
      metadata: "priv/models_dev/my_provider.json"

        def attach(request, model) do
          # Provider-specific request configuration
        end

        def parse(response, model) do
          # Provider-specific response parsing
        end
      end

  ## Options

    * `:id` - Unique provider identifier (required atom)
    * `:base_url` - Default API base URL (required string)
    * `:metadata` - Path to JSON metadata file (optional string)
    * `:context_wrapper` - Module name for context wrapper struct (optional atom)
    * `:response_wrapper` - Module name for response wrapper struct (optional atom)
    * `:provider_schema` - NimbleOptions schema defining supported options and defaults (optional keyword list)

  ## Generated Code

  The DSL automatically generates:

  1. **Plugin Behaviour**: `use Req.Plugin`
  2. **Default Base URL**: `def default_base_url(), do: "https://api.example.com/v1"`
  3. **Registry Registration**: Calls `ReqLLM.Provider.Registry.register/3`
  4. **Metadata Loading**: Loads and parses JSON metadata at compile time

  ## Metadata Files

  Metadata files should contain JSON with model information:

      {
        "models": [
          {
            "id": "my-model-1",
            "context_length": 8192,
            "capabilities": ["text_generation"],
            "pricing": {
              "input": 0.001,
              "output": 0.002
            }
          }
        ],
        "capabilities": ["text_generation", "embeddings"],
        "documentation": "https://api.example.com/docs"
      }

  ## Example Implementation

      defmodule ReqLLM.Providers.Example do
      use ReqLLM.Provider.DSL,
      id: :example,
      base_url: "https://api.example.com/v1",
      metadata: "priv/models_dev/example.json",
      context_wrapper: ReqLLM.Providers.Example.Context,
      response_wrapper: ReqLLM.Providers.Example.Response,
      provider_schema: [
        temperature: [type: :float, default: 0.7],
        max_tokens: [type: :pos_integer, default: 1024],
        stream: [type: :boolean, default: false],
        api_version: [type: :string, default: "2023-06-01"]
      ]

        def attach(request, %ReqLLM.Model{} = model) do
          api_key = ReqLLM.get_key(:example_api_key)

          request
          |> Req.Request.put_header("authorization", "Bearer \#{api_key}")
          |> Req.Request.put_header("content-type", "application/json")
          |> Req.Request.put_base_url(default_base_url())
          |> Req.Request.put_body(%{
            model: model.model,
            messages: format_messages(model.context),
            temperature: model.temperature
          })
        end

        def parse(response, %ReqLLM.Model{} = model) do
          case response.body do
            %{"content" => content} ->
              {:ok, content}
            %{"error" => error} ->
              {:error, ReqLLM.Error.api_error(error)}
            _ ->
              {:error, ReqLLM.Error.parse_error("Invalid response format")}
          end
        end

        # Private helper functions...
      end

  """

  @doc """
  Sigil for defining lists of atoms from space-separated words.

  ## Examples

      ~a[temperature max_tokens top_p]  # => [:temperature, :max_tokens, :top_p]
  """

  # defmacro sigil_a({:<<>>, _, [string]}, _mods) do
  #   list =
  #     string
  #     |> String.split(~r/\s+/, trim: true)
  #     |> Enum.map(&String.to_atom/1)

  #   Macro.escape(list)
  # end

  defmacro __using__(opts) do
    # Validate required options
    id = Keyword.fetch!(opts, :id)
    base_url = Keyword.fetch!(opts, :base_url)
    metadata_path = Keyword.get(opts, :metadata)
    provider_schema = Keyword.get(opts, :provider_schema, [])
    default_env_key = Keyword.get(opts, :default_env_key)
    context_wrapper = Keyword.get(opts, :context_wrapper)
    response_wrapper = Keyword.get(opts, :response_wrapper)

    if !is_atom(id) do
      raise ArgumentError, "Provider :id must be an atom, got: #{inspect(id)}"
    end

    if !is_binary(base_url) do
      raise ArgumentError, "Provider :base_url must be a string, got: #{inspect(base_url)}"
    end

    if default_env_key && !is_binary(default_env_key) do
      raise ArgumentError,
            "Provider :default_env_key must be a string, got: #{inspect(default_env_key)}"
    end

    quote do
      # Implement Req plugin pattern (no formal behaviour needed)

      # Store configuration for use in callbacks
      @provider_id unquote(id)
      @base_url unquote(base_url)
      @metadata_path unquote(metadata_path)
      @provider_schema_opts unquote(provider_schema)
      @default_env_key unquote(default_env_key)
      @context_wrapper unquote(context_wrapper)
      @response_wrapper unquote(response_wrapper)

      # Set external resource if metadata file exists
      if @metadata_path do
        @external_resource @metadata_path
      end

      # Register provider before compilation completes
      @before_compile ReqLLM.Provider.DSL

      # Implement default_base_url function
      def default_base_url do
        @base_url
      end

      defoverridable default_base_url: 0
    end
  end

  defmacro __before_compile__(env) do
    # Get the compiled module's attributes
    provider_id = Module.get_attribute(env.module, :provider_id)
    metadata_path = Module.get_attribute(env.module, :metadata_path)
    provider_schema_opts = Module.get_attribute(env.module, :provider_schema_opts)
    default_env_key = Module.get_attribute(env.module, :default_env_key)
    context_wrapper = Module.get_attribute(env.module, :context_wrapper)
    response_wrapper = Module.get_attribute(env.module, :response_wrapper)

    # Load metadata if file exists
    metadata = load_metadata(metadata_path)

    # Build provider schema from opts, falling back to all generation keys if empty
    provider_schema_definition = build_provider_schema(provider_schema_opts)

    quote do
      # Store metadata as module attribute
      @req_llm_metadata unquote(Macro.escape(metadata))

      # Build the provider schema at compile time
      @provider_schema unquote(provider_schema_definition)

      # Optional helpers for accessing provider info
      def metadata, do: @req_llm_metadata
      def provider_id, do: unquote(provider_id)

      # Provider option helpers
      def supported_provider_options do
        # Return both core generation options and provider-specific options
        core_options = ReqLLM.Provider.Options.all_generation_keys()
        provider_options = @provider_schema.schema |> Keyword.keys()
        # Exclude :provider_options as it's a meta-key, not an actual validation target
        (core_options ++ provider_options) |> Enum.reject(&(&1 == :provider_options))
      end

      def default_provider_opts do
        @provider_schema.schema
        |> Enum.filter(fn {_key, opts} -> Keyword.has_key?(opts, :default) end)
        |> Enum.map(fn {key, opts} -> {key, opts[:default]} end)
      end

      def provider_schema, do: @provider_schema

      # Translation helper functions available to all providers
      @doc false
      def validate_mutex!(opts, keys, msg) when is_list(keys) do
        present = Enum.filter(keys, &Keyword.has_key?(opts, &1))

        if length(present) > 1 do
          raise ReqLLM.Error.Invalid.Parameter.exception(parameter: msg)
        end

        :ok
      end

      @doc false
      def translate_rename(opts, from, to) when is_atom(from) and is_atom(to) do
        validate_mutex!(opts, [from, to], "#{from} and #{to} cannot be used together")

        case Keyword.pop(opts, from) do
          {nil, opts} -> {opts, []}
          {value, opts} -> {Keyword.put(opts, to, value), []}
        end
      end

      @doc false
      def translate_drop(opts, key, msg \\ nil) do
        {value, opts} = Keyword.pop(opts, key)
        warnings = if value != nil && msg, do: [msg], else: []
        {opts, warnings}
      end

      @doc false
      def translate_combine_warnings(results) do
        {final_opts, all_warnings} =
          Enum.reduce(results, {[], []}, fn {opts, warnings}, {acc_opts, acc_warns} ->
            {Keyword.merge(acc_opts, opts), acc_warns ++ warnings}
          end)

        {final_opts, all_warnings}
      end

      # Generate default_env_key callback if provided
      unquote(
        if default_env_key do
          quote do
            def default_env_key, do: unquote(default_env_key)
          end
        end
      )

      # Generate wrap_context callback if wrapper is provided
      unquote(
        if context_wrapper do
          quote do
            @doc false
            def wrap_context(%ReqLLM.Context{} = ctx) do
              struct!(unquote(context_wrapper), context: ctx)
            end
          end
        end
      )

      # Generate wrap_response callback if wrapper is provided
      unquote(
        if response_wrapper do
          quote do
            # 1. Avoid double wrapping (can happen in tests)
            @doc false
            def wrap_response(%unquote(response_wrapper){} = already_wrapped), do: already_wrapped

            # 2. Wrap everything (including streams) in provider-specific struct
            @doc false
            def wrap_response(data), do: struct!(unquote(response_wrapper), payload: data)
          end
        end
      )
    end
  end

  # Private helper to build provider schema from options
  defp build_provider_schema([]) do
    # Return empty schema - providers must explicitly declare what they support
    quote do
      NimbleOptions.new!([])
    end
  end

  defp build_provider_schema(schema_opts) when is_list(schema_opts) do
    # Validate that provider schema keys don't overlap with core generation schema
    validate_schema_keys(schema_opts)

    # Build schema directly from provider-specific options
    quote do
      NimbleOptions.new!(unquote(schema_opts))
    end
  end

  # Compile-time validation that provider schema keys don't overlap with core options
  defp validate_schema_keys(schema_opts) do
    core_keys = ReqLLM.Generation.schema().schema |> Keyword.keys()

    Enum.each(schema_opts, fn {key, _opts} ->
      if key in core_keys do
        raise CompileError,
          description:
            "Provider schema key #{inspect(key)} conflicts with core generation option. " <>
              "Core keys: #{inspect(core_keys)}. " <>
              "Provider-specific options should be unique to the provider."
      end
    end)
  end

  # Private helper to load metadata at compile time
  defp load_metadata(nil), do: %{}

  defp load_metadata(path) when is_binary(path) do
    full_path = Path.expand(path)

    if File.exists?(full_path) do
      case File.read(full_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              # Convert string keys to atom keys for easier access
              atomize_keys(data)

            {:error, error} ->
              IO.warn("Failed to parse JSON metadata from #{path}: #{inspect(error)}")
              %{}
          end

        {:error, error} ->
          IO.warn("Failed to read metadata file #{path}: #{inspect(error)}")
          %{}
      end
    else
      IO.warn("Metadata file not found: #{path}")
      %{}
    end
  end

  # Helper to recursively convert string keys to atoms (for known keys only)
  defp atomize_keys(data) when is_map(data) do
    data
    |> Map.new(fn
      {"models", value} -> {:models, atomize_keys(value)}
      {"capabilities", value} -> {:capabilities, value}
      {"pricing", value} -> {:pricing, atomize_keys(value)}
      {"context_length", value} -> {:context_length, value}
      {"id", value} -> {:id, value}
      {"input", value} -> {:input, value}
      {"output", value} -> {:output, value}
      {key, value} -> {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(data) when is_list(data) do
    Enum.map(data, &atomize_keys/1)
  end

  defp atomize_keys(data), do: data
end
