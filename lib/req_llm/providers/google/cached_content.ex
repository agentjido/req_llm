defmodule ReqLLM.Providers.Google.CachedContent do
  @moduledoc """
  Shared functionality for Google's Context Caching API.

  Both Google AI Studio and Vertex AI support explicit context caching
  through the CachedContent API **for Gemini models only**. Claude models
  on Vertex AI do not support context caching. This module provides shared
  logic for creating and managing cached content.

  ## Overview

  Context caching allows you to cache large amounts of content (system instructions,
  documents, videos, etc.) and reference them in multiple requests, reducing costs
  and latency. This feature is available for Gemini 2.0 and 2.5 models.

  ## Minimum Requirements

  - Gemini 2.5 Flash: 1,024 tokens minimum
  - Gemini 2.5 Pro: 4,096 tokens minimum

  ## HTTP Options

  Every function in this module accepts the following options in addition to
  the ones listed in its documentation:

  - `:base_url` - Override the API base URL (e.g. for proxies or test servers).
    For Google AI Studio the default is `"https://generativelanguage.googleapis.com/v1beta"`.
    For Vertex AI the default is `"https://{region}-aiplatform.googleapis.com/v1"` for
    `create/1` and `list/1`, and `"https://aiplatform.googleapis.com/v1"` for the
    name-based operations (`get/1`, `update/1`, `delete/1`), whose `:name` is a full
    resource path.
  - `:receive_timeout` - Timeout for receiving the response in milliseconds
    (defaults to `120_000`).
  - `:req_http_options` - Keyword list of `Req` options merged into the underlying
    request (e.g. `finch: [name: MyFinch]`, `retry: false`, or
    `plug: {Req.Test, MyStub}` for testing). Requests run through ReqLLM's Finch
    pool (`ReqLLM.Finch`) unless a `:finch` option is given.

  ## Cost Savings

  - Gemini 2.5: 90% discount on cached tokens
  - Gemini 2.0: 75% discount on cached tokens
  - Storage costs apply based on TTL

  ## Complete Workflow Example

      # Step 1: Create cached content with a large document
      large_document = File.read!("large_document.txt")

      {:ok, cache} = ReqLLM.Providers.Google.CachedContent.create(
        provider: :google,
        model: "gemini-2.5-flash",
        api_key: System.get_env("GOOGLE_API_KEY"),
        contents: [
          %{role: "user", parts: [%{text: large_document}]}
        ],
        system_instruction: "You are a helpful assistant that answers questions about the provided document.",
        ttl: "3600s",
        display_name: "Document Analysis Cache"
      )

      # Step 2: Use the cache in multiple requests (90% discount on cached tokens!)
      {:ok, response1} = ReqLLM.generate_text(
        "google:gemini-2.5-flash",
        "What is the main topic of the document?",
        provider_options: [cached_content: cache.name]
      )

      {:ok, response2} = ReqLLM.generate_text(
        "google:gemini-2.5-flash",
        "Summarize the key points.",
        provider_options: [cached_content: cache.name]
      )

      # Step 3: Check token usage (note the cached_tokens field)
      IO.inspect(response1.usage)
      # %{input_tokens: 50, cached_tokens: 10000, output_tokens: 100, ...}

      # Step 4: Extend cache lifetime if needed
      {:ok, updated_cache} = ReqLLM.Providers.Google.CachedContent.update(
        provider: :google,
        name: cache.name,
        api_key: System.get_env("GOOGLE_API_KEY"),
        ttl: "7200s"
      )

      # Step 5: Clean up when done
      :ok = ReqLLM.Providers.Google.CachedContent.delete(
        provider: :google,
        name: cache.name,
        api_key: System.get_env("GOOGLE_API_KEY")
      )

  ## Vertex AI Example

      # Vertex AI uses full resource paths for cache names
      {:ok, cache} = ReqLLM.Providers.Google.CachedContent.create(
        provider: :google_vertex,
        model: "gemini-2.5-flash",
        service_account_json: System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
        project_id: "my-project",
        region: "us-central1",
        contents: [%{role: "user", parts: [%{text: large_document}]}],
        system_instruction: "You are a helpful assistant.",
        ttl: "3600s"
      )

      # Use in requests
      {:ok, response} = ReqLLM.generate_text(
        "google-vertex:gemini-2.5-flash",
        "Question about the document?",
        provider_options: [
          cached_content: cache.name,
          service_account_json: System.get_env("GOOGLE_APPLICATION_CREDENTIALS"),
          project_id: "my-project"
        ]
      )

  """

  @google_ai_studio_base_url "https://generativelanguage.googleapis.com/v1beta"
  @vertex_global_base_url "https://aiplatform.googleapis.com/v1"
  @default_receive_timeout 120_000

  @doc """
  Creates a new cached content resource.

  ## Options

  - `:provider` - Either `:google` (AI Studio) or `:google_vertex` (Vertex AI)
  - `:model` - Model identifier (e.g., "gemini-2.5-flash")
  - `:api_key` - API key (for Google AI Studio)
  - `:service_account_json` - Service account JSON path (for Vertex AI)
  - `:project_id` - GCP project ID (for Vertex AI)
  - `:region` - GCP region (for Vertex AI, defaults to "us-central1")
  - `:contents` - List of content to cache (messages format)
  - `:system_instruction` - Optional system instruction to cache
  - `:tools` - Optional tools to cache
  - `:tool_config` - Optional tool configuration
  - `:ttl` - Time-to-live duration (e.g., "3600s", defaults to "3600s")
  - `:display_name` - Optional display name for the cache
  - `:base_url` - Optional API base URL override (see "HTTP Options" in the moduledoc)
  - `:receive_timeout` - Optional response timeout in milliseconds (defaults to 120000)
  - `:req_http_options` - Optional `Req` options for the underlying request

  ## Returns

  `{:ok, cache_info}` where cache_info contains:
  - `:name` - The cache resource name/ID to use in requests
  - `:create_time` - When the cache was created
  - `:update_time` - When the cache was last updated
  - `:expire_time` - When the cache will expire
  - `:usage_metadata` - Token counts for the cached content

  ## Examples

      # Google AI Studio
      {:ok, cache} = create(
        provider: :google,
        model: "gemini-2.5-flash",
        api_key: "your-api-key",
        contents: [%{role: "user", parts: [%{text: "Content to cache"}]}],
        ttl: "3600s"
      )

      # Vertex AI
      {:ok, cache} = create(
        provider: :google_vertex,
        model: "gemini-2.5-flash",
        service_account_json: "/path/to/service-account.json",
        project_id: "your-project",
        region: "us-central1",
        contents: [%{role: "user", parts: [%{text: "Content to cache"}]}],
        ttl: "3600s"
      )
  """
  def create(opts) do
    provider = Keyword.fetch!(opts, :provider)

    case provider do
      :google ->
        create_google_ai_studio(opts)

      :google_vertex ->
        create_vertex_ai(opts)

      :google_vertex_anthropic ->
        {:error, "Context caching is only supported for Gemini models on Vertex AI"}

      other ->
        {:error, "Unsupported provider for context caching: #{inspect(other)}"}
    end
  end

  @doc """
  Lists all cached content resources.

  ## Options

  - `:provider` - Either `:google` or `:google_vertex`
  - `:api_key` - API key (for Google AI Studio)
  - `:service_account_json` - Service account JSON path (for Vertex AI)
  - `:project_id` - GCP project ID (for Vertex AI)
  - `:region` - GCP region (for Vertex AI)
  - `:page_size` - Number of results per page (optional)
  - `:page_token` - Token for pagination (optional)
  - `:base_url` - Optional API base URL override (see "HTTP Options" in the moduledoc)
  - `:receive_timeout` - Optional response timeout in milliseconds (defaults to 120000)
  - `:req_http_options` - Optional `Req` options for the underlying request
  """
  def list(opts) do
    provider = Keyword.fetch!(opts, :provider)

    case provider do
      :google -> list_google_ai_studio(opts)
      :google_vertex -> list_vertex_ai(opts)
      other -> {:error, "Unsupported provider: #{inspect(other)}"}
    end
  end

  @doc """
  Gets details about a specific cached content resource.

  ## Options

  - `:provider` - Either `:google` or `:google_vertex`
  - `:name` - The cache resource name/ID
  - `:api_key` - API key (for Google AI Studio)
  - `:service_account_json` - Service account JSON path (for Vertex AI)
  - `:project_id` - GCP project ID (for Vertex AI)
  - `:region` - GCP region (for Vertex AI)
  - `:base_url` - Optional API base URL override (see "HTTP Options" in the moduledoc)
  - `:receive_timeout` - Optional response timeout in milliseconds (defaults to 120000)
  - `:req_http_options` - Optional `Req` options for the underlying request
  """
  def get(opts) do
    provider = Keyword.fetch!(opts, :provider)

    case provider do
      :google -> get_google_ai_studio(opts)
      :google_vertex -> get_vertex_ai(opts)
      other -> {:error, "Unsupported provider: #{inspect(other)}"}
    end
  end

  @doc """
  Updates the TTL of an existing cached content resource.

  ## Options

  - `:provider` - Either `:google` or `:google_vertex`
  - `:name` - The cache resource name/ID
  - `:ttl` - New time-to-live duration (e.g., "7200s")
  - `:api_key` - API key (for Google AI Studio)
  - `:service_account_json` - Service account JSON path (for Vertex AI)
  - `:project_id` - GCP project ID (for Vertex AI)
  - `:region` - GCP region (for Vertex AI)
  - `:base_url` - Optional API base URL override (see "HTTP Options" in the moduledoc)
  - `:receive_timeout` - Optional response timeout in milliseconds (defaults to 120000)
  - `:req_http_options` - Optional `Req` options for the underlying request
  """
  def update(opts) do
    provider = Keyword.fetch!(opts, :provider)

    case provider do
      :google -> update_google_ai_studio(opts)
      :google_vertex -> update_vertex_ai(opts)
      other -> {:error, "Unsupported provider: #{inspect(other)}"}
    end
  end

  @doc """
  Deletes a cached content resource.

  ## Options

  - `:provider` - Either `:google` or `:google_vertex`
  - `:name` - The cache resource name/ID
  - `:api_key` - API key (for Google AI Studio)
  - `:service_account_json` - Service account JSON path (for Vertex AI)
  - `:project_id` - GCP project ID (for Vertex AI)
  - `:region` - GCP region (for Vertex AI)
  - `:base_url` - Optional API base URL override (see "HTTP Options" in the moduledoc)
  - `:receive_timeout` - Optional response timeout in milliseconds (defaults to 120000)
  - `:req_http_options` - Optional `Req` options for the underlying request
  """
  def delete(opts) do
    provider = Keyword.fetch!(opts, :provider)

    case provider do
      :google -> delete_google_ai_studio(opts)
      :google_vertex -> delete_vertex_ai(opts)
      other -> {:error, "Unsupported provider: #{inspect(other)}"}
    end
  end

  # Private functions for Google AI Studio

  defp create_google_ai_studio(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.fetch!(opts, :model)
    contents = Keyword.fetch!(opts, :contents)

    ttl = Keyword.get(opts, :ttl, "3600s")
    system_instruction = Keyword.get(opts, :system_instruction)
    tools = Keyword.get(opts, :tools)
    tool_config = Keyword.get(opts, :tool_config)
    display_name = Keyword.get(opts, :display_name)

    body =
      %{
        model: "models/#{model}",
        contents: contents,
        ttl: ttl
      }
      |> maybe_put(:systemInstruction, format_system_instruction(system_instruction))
      |> maybe_put(:tools, tools)
      |> maybe_put(:toolConfig, tool_config)
      |> maybe_put(:displayName, display_name)

    request_options =
      http_options(@google_ai_studio_base_url, [json: body, params: [key: api_key]], opts)

    case Req.post("/cachedContents", request_options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, parse_cache_response(response)}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to create cached content (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp list_google_ai_studio(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    page_size = Keyword.get(opts, :page_size)
    page_token = Keyword.get(opts, :page_token)

    params =
      [key: api_key]
      |> maybe_put_param(:pageSize, page_size)
      |> maybe_put_param(:pageToken, page_token)

    request_options = http_options(@google_ai_studio_base_url, [params: params], opts)

    case Req.get("/cachedContents", request_options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to list cached content (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp get_google_ai_studio(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    name = Keyword.fetch!(opts, :name)

    request_options = http_options(@google_ai_studio_base_url, [params: [key: api_key]], opts)

    case Req.get("/#{name}", request_options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, parse_cache_response(response)}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to get cached content (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp update_google_ai_studio(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    name = Keyword.fetch!(opts, :name)
    ttl = Keyword.fetch!(opts, :ttl)

    body = %{ttl: ttl}

    request_options =
      http_options(
        @google_ai_studio_base_url,
        [json: body, params: [key: api_key, updateMask: "ttl"]],
        opts
      )

    case Req.patch("/#{name}", request_options) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, parse_cache_response(response)}

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to update cached content (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp delete_google_ai_studio(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    name = Keyword.fetch!(opts, :name)

    request_options = http_options(@google_ai_studio_base_url, [params: [key: api_key]], opts)

    case Req.delete("/#{name}", request_options) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Failed to delete cached content (status #{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  # Private functions for Vertex AI

  defp create_vertex_ai(opts) do
    service_account_json = Keyword.fetch!(opts, :service_account_json)
    project_id = Keyword.fetch!(opts, :project_id)
    model = Keyword.fetch!(opts, :model)
    contents = Keyword.fetch!(opts, :contents)

    region = Keyword.get(opts, :region, "us-central1")

    # Validate region - caching API doesn't support "global"
    if region == "global" do
      {:error,
       "Context caching does not support 'global' region. Please specify a specific region like 'us-central1', 'us-east1', or 'europe-west1'."}
    else
      do_create_vertex_ai(
        service_account_json,
        project_id,
        model,
        contents,
        region,
        opts
      )
    end
  end

  defp do_create_vertex_ai(service_account_json, project_id, model, contents, region, opts) do
    ttl = Keyword.get(opts, :ttl, "3600s")
    system_instruction = Keyword.get(opts, :system_instruction)
    tools = Keyword.get(opts, :tools)
    tool_config = Keyword.get(opts, :tool_config)
    display_name = Keyword.get(opts, :display_name)

    body =
      %{
        model: "projects/#{project_id}/locations/#{region}/publishers/google/models/#{model}",
        contents: contents,
        ttl: ttl
      }
      |> maybe_put(:systemInstruction, format_system_instruction(system_instruction))
      |> maybe_put(:tools, tools)
      |> maybe_put(:toolConfig, tool_config)
      |> maybe_put(:displayName, display_name)

    url = "/projects/#{project_id}/locations/#{region}/cachedContents"

    with {:ok, access_token} <-
           ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json) do
      headers = [{"authorization", "Bearer #{access_token}"}]

      request_options =
        http_options(vertex_regional_base_url(region), [json: body, headers: headers], opts)

      case Req.post(url, request_options) do
        {:ok, %{status: 200, body: response}} ->
          {:ok, parse_cache_response(response)}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to create cached content (status #{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end
  end

  defp list_vertex_ai(opts) do
    service_account_json = Keyword.fetch!(opts, :service_account_json)
    project_id = Keyword.fetch!(opts, :project_id)
    region = Keyword.get(opts, :region, "us-central1")

    # Validate region
    if region == "global" do
      {:error,
       "Context caching does not support 'global' region. Please specify a specific region like 'us-central1', 'us-east1', or 'europe-west1'."}
    else
      page_size = Keyword.get(opts, :page_size)
      page_token = Keyword.get(opts, :page_token)

      url = "/projects/#{project_id}/locations/#{region}/cachedContents"

      params =
        []
        |> maybe_put_param(:pageSize, page_size)
        |> maybe_put_param(:pageToken, page_token)

      with {:ok, access_token} <-
             ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json) do
        headers = [{"authorization", "Bearer #{access_token}"}]

        request_options =
          http_options(vertex_regional_base_url(region), [params: params, headers: headers], opts)

        case Req.get(url, request_options) do
          {:ok, %{status: 200, body: response}} ->
            {:ok, response}

          {:ok, %{status: status, body: body}} ->
            {:error, "Failed to list cached content (status #{status}): #{inspect(body)}"}

          {:error, reason} ->
            {:error, "Request failed: #{inspect(reason)}"}
        end
      end
    end
  end

  defp get_vertex_ai(opts) do
    service_account_json = Keyword.fetch!(opts, :service_account_json)
    name = Keyword.fetch!(opts, :name)

    # Name should be full resource path: projects/{project}/locations/{region}/cachedContents/{id}
    with {:ok, access_token} <-
           ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json) do
      headers = [{"authorization", "Bearer #{access_token}"}]
      request_options = http_options(@vertex_global_base_url, [headers: headers], opts)

      case Req.get("/#{name}", request_options) do
        {:ok, %{status: 200, body: response}} ->
          {:ok, parse_cache_response(response)}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to get cached content (status #{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end
  end

  defp update_vertex_ai(opts) do
    service_account_json = Keyword.fetch!(opts, :service_account_json)
    name = Keyword.fetch!(opts, :name)
    ttl = Keyword.fetch!(opts, :ttl)

    body = %{ttl: ttl}

    with {:ok, access_token} <-
           ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json) do
      headers = [{"authorization", "Bearer #{access_token}"}]

      request_options =
        http_options(
          @vertex_global_base_url,
          [json: body, params: [updateMask: "ttl"], headers: headers],
          opts
        )

      case Req.patch("/#{name}", request_options) do
        {:ok, %{status: 200, body: response}} ->
          {:ok, parse_cache_response(response)}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to update cached content (status #{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end
  end

  defp delete_vertex_ai(opts) do
    service_account_json = Keyword.fetch!(opts, :service_account_json)
    name = Keyword.fetch!(opts, :name)

    with {:ok, access_token} <-
           ReqLLM.Providers.GoogleVertex.Auth.get_access_token(service_account_json) do
      headers = [{"authorization", "Bearer #{access_token}"}]
      request_options = http_options(@vertex_global_base_url, [headers: headers], opts)

      case Req.delete("/#{name}", request_options) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to delete cached content (status #{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end
  end

  # Shared helper functions

  defp vertex_regional_base_url(region), do: "https://#{region}-aiplatform.googleapis.com/v1"

  defp http_options(default_base_url, request_options, opts) do
    http_opts = Keyword.get(opts, :req_http_options, [])
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)

    [
      base_url: Keyword.get(opts, :base_url, default_base_url),
      receive_timeout: receive_timeout
    ] ++
      request_options ++
      ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: receive_timeout)
  end

  defp format_system_instruction(nil), do: nil
  defp format_system_instruction(text) when is_binary(text), do: %{parts: [%{text: text}]}
  defp format_system_instruction(instruction) when is_map(instruction), do: instruction

  defp parse_cache_response(response) when is_map(response) do
    %{
      name: Map.get(response, "name"),
      create_time: Map.get(response, "createTime"),
      update_time: Map.get(response, "updateTime"),
      expire_time: Map.get(response, "expireTime"),
      usage_metadata: Map.get(response, "usageMetadata"),
      model: Map.get(response, "model"),
      display_name: Map.get(response, "displayName")
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Keyword.put(params, key, value)
end
