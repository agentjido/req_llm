Mix.install([
  {:phoenix_playground, "~> 0.1.8"},
  # {:jason, "~> 1.4"},
  {:req_llm, path: "."},
  {:llm_db, path: "./deps/llm_db", override: true},
  {:dotenvy, "~> 1.0"}
])

# Load .env file
env_map = Dotenvy.source!([".env", System.user_home!() <> "/.env"])
System.put_env(env_map)

defmodule ReqLLMPlaygroundLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    saved = load_config()

    default_key =
      (System.get_env("ZENMUX_API_KEY") || System.get_env("LB_API_KEY") ||
         System.get_env("OPENAI_API_KEY") || System.get_env("OPENROUTER_API_KEY") || "")
      |> String.trim()

    initial_mode = Map.get(saved, "base_url_mode") || "openrouter"
    models = fetch_models(initial_mode)

    {:ok,
     assign(socket,
       api_key: Map.get(saved, "api_key") || default_key,
       base_url_mode: initial_mode,
       custom_base_url: Map.get(saved, "custom_base_url") || "",
       custom_adapter: Map.get(saved, "custom_adapter") || "openai",
       model: Map.get(saved, "model") || "google/gemma-2-9b-it:free",
       available_models: models,
       system_prompt: Map.get(saved, "system_prompt") || "You are a helpful assistant.",
       user_prompt: Map.get(saved, "user_prompt") || "Tell me a short joke about Elixir.",
       response: nil,
       usage: nil,
       error: nil,
       loading: false,
       logs: []
     )}
  end

  def render(assigns) do
    ~H"""
    <script src="https://cdn.tailwindcss.com"></script>
    <div class="min-h-screen bg-gray-50 py-8 px-4 sm:px-6 lg:px-8 font-sans">
      <div class="max-w-4xl mx-auto bg-white rounded-xl shadow-lg overflow-hidden">

        <!-- Header -->
        <div class="bg-indigo-600 px-6 py-4">
          <h1 class="text-2xl font-bold text-white flex items-center gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-8 h-8">
              <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12h1.5m1.875 5.775 1.5 1.5M12 18.75v1.5m-4.125-2.25 1.5-1.5m5.25 5.25v-1.5m1.5-1.5 1.5 1.5m-1.5-1.5-1.5 1.5M19.5 8.25h1.5M12 3v1.5m0 0c2.828 0 5.25 1.5 6.75 3.75h-13.5c1.5-2.25 3.922-3.75 6.75-3.75Z" />
            </svg>
            ReqLLM Playground
          </h1>
          <p class="text-indigo-100 text-sm mt-1">Test and debug LLM requests interactively</p>
        </div>

        <div class="p-6 grid grid-cols-1 lg:grid-cols-2 gap-8">

          <!-- Left Column: Configuration -->
          <div class="space-y-6">
            <h2 class="text-lg font-semibold text-gray-800 border-b pb-2">Configuration</h2>

            <form phx-change="validate" phx-submit="run_request" class="space-y-4">

              <!-- API Key -->
              <div>
                <label class="block text-sm font-medium text-gray-700">API Key</label>
                <div class="mt-1 relative rounded-md shadow-sm">
                  <input type="password" name="api_key" value={@api_key}
                    class="block w-full px-3 py-2 border border-gray-300 rounded-md focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm"
                    placeholder="sk-..." />
                </div>
              </div>

              <!-- Base URL Config -->
              <div class="bg-gray-50 p-3 rounded-md border border-gray-200 space-y-3">
                <label class="block text-sm font-medium text-gray-700">Provider / Base URL</label>
                <div class="flex flex-wrap gap-4">
                  <label class="flex items-center">
                    <input type="radio" name="base_url_mode" value="openrouter" checked={@base_url_mode == "openrouter"} class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300" />
                    <span class="ml-2 text-sm text-gray-700">OpenRouter</span>
                  </label>
                  <label class="flex items-center">
                    <input type="radio" name="base_url_mode" value="openai" checked={@base_url_mode == "openai"} class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300" />
                    <span class="ml-2 text-sm text-gray-700">OpenAI</span>
                  </label>
                  <label class="flex items-center">
                    <input type="radio" name="base_url_mode" value="zenmux" checked={@base_url_mode == "zenmux"} class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300" />
                    <span class="ml-2 text-sm text-gray-700">ZenMux</span>
                  </label>
                  <label class="flex items-center">
                    <input type="radio" name="base_url_mode" value="local" checked={@base_url_mode == "local"} class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300" />
                    <span class="ml-2 text-sm text-gray-700">Local</span>
                  </label>
                  <label class="flex items-center">
                    <input type="radio" name="base_url_mode" value="custom" checked={@base_url_mode == "custom"} class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300" />
                    <span class="ml-2 text-sm text-gray-700">Custom</span>
                  </label>
                </div>

                <%= if @base_url_mode == "custom" do %>
                  <div class="space-y-3 pt-2">
                    <div>
                      <label class="block text-xs font-medium text-gray-500 uppercase">API Adapter / Style</label>
                      <select name="custom_adapter" class="mt-1 block w-full pl-3 pr-10 py-2 text-base border-gray-300 focus:outline-none focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm rounded-md">
                        <%= for option <- ["openai", "anthropic", "openrouter", "zenmux","google", "ollama", "mistral", "xai"] do %>
                          <option value={option} selected={@custom_adapter == option}>{String.capitalize(option)}</option>
                        <% end %>
                      </select>
                      <p class="mt-1 text-xs text-gray-500">Determines request formatting (e.g. OpenAI vs Anthropic).</p>
                    </div>

                    <div>
                      <label class="block text-xs font-medium text-gray-500 uppercase">Base URL</label>
                      <input type="text" name="custom_base_url" value={@custom_base_url}
                        class="mt-1 block w-full px-3 py-2 border border-gray-300 rounded-md focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm"
                        placeholder="https://api.example.com/v1" />
                    </div>
                  </div>
                <% end %>

                <div class="text-xs text-gray-500 italic">
                  Current Base URL: <span class="font-mono text-gray-700">{get_base_url(@base_url_mode, @custom_base_url)}</span>
                </div>
              </div>

              <!-- Model -->
              <div>
                <div class="flex justify-between items-center mb-1">
                  <label class="block text-sm font-medium text-gray-700">Model Name</label>
                  <button type="button" phx-click="refresh_models" class="text-xs text-indigo-600 hover:text-indigo-800 flex items-center">
                    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-3 h-3 mr-1">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99" />
                    </svg>
                    Refresh List
                  </button>
                </div>

                <input type="text" name="model" value={@model} list="model-list" autocomplete="off"
                  class="block w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm font-mono"
                  placeholder="Select or type model name..." />

                <datalist id="model-list">
                  <%= for m <- @available_models do %>
                    <option value={m} />
                  <% end %>
                </datalist>
                <p class="mt-1 text-xs text-gray-500">
                  Select from list (loaded from LLMDB) or type a custom model ID.
                </p>
              </div>

              <!-- Prompts -->
              <div>
                <label class="block text-sm font-medium text-gray-700">System Prompt</label>
                <textarea name="system_prompt" rows="2"
                  class="mt-1 block w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm">{@system_prompt}</textarea>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700">User Prompt</label>
                <textarea name="user_prompt" rows="4"
                  class="mt-1 block w-full px-3 py-2 border border-gray-300 rounded-md shadow-sm focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm">{@user_prompt}</textarea>
              </div>

              <!-- Action Button -->
              <div class="pt-2">
                <button type="submit" disabled={@loading}
                  class={"w-full flex justify-center py-2.5 px-4 border border-transparent rounded-md shadow-sm text-sm font-semibold text-white transition duration-150 ease-in-out " <>
                  (if @loading, do: "bg-indigo-400 cursor-wait", else: "bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500")}>
                  <%= if @loading do %>
                    <svg class="animate-spin -ml-1 mr-3 h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Generating Response...
                  <% else %>
                    Send Request
                  <% end %>
                </button>
              </div>
            </form>

            <!-- Logs -->
            <div class="mt-8 border-t border-gray-200 pt-4">
               <h3 class="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">Request Log</h3>
               <div class="bg-gray-900 rounded-md p-3 h-48 overflow-y-auto text-xs font-mono text-green-400">
                 <%= for log <- Enum.reverse(@logs) do %>
                   <div class="mb-1 border-b border-gray-800 pb-1 last:border-0 last:pb-0">
                     <span class="text-gray-500 select-none">&gt;{Calendar.strftime(log.time, "%H:%M:%S")}&lt; </span>
                     {log.msg}
                   </div>
                 <% end %>
                 <%= if Enum.empty?(@logs), do: "Ready..." %>
               </div>
            </div>

          </div>

          <!-- Right Column: Result -->
          <div class="flex flex-col h-full">
             <h2 class="text-lg font-semibold text-gray-800 border-b pb-2 mb-4">Response</h2>

             <div class="flex-grow bg-gray-50 border border-gray-200 rounded-md p-4 overflow-y-auto min-h-[400px]">
               <%= if @error do %>
                  <div class="text-red-600 bg-red-50 p-4 rounded-md border border-red-200">
                    <strong class="block mb-2 font-bold">Error Occurred:</strong>
                    <pre class="whitespace-pre-wrap text-sm font-mono overflow-x-auto">{@error}</pre>
                  </div>
               <% else %>
                  <%= if @response do %>
                    <div class="prose prose-sm max-w-none text-gray-800 whitespace-pre-wrap">{@response}</div>

                    <%= if @usage do %>
                      <div class="mt-6 pt-4 border-t border-gray-200">
                         <h4 class="text-xs font-bold text-gray-500 uppercase mb-2">Token Usage</h4>
                         <div class="grid grid-cols-3 gap-2 text-xs text-center">
                            <div class="bg-white p-2 border rounded shadow-sm">
                              <div class="text-gray-500">Input</div>
                              <div class="font-mono font-bold">{@usage["input_tokens"] || @usage[:input_tokens] || "-"}</div>
                            </div>
                            <div class="bg-white p-2 border rounded shadow-sm">
                              <div class="text-gray-500">Output</div>
                              <div class="font-mono font-bold">{@usage["output_tokens"] || @usage[:output_tokens] || "-"}</div>
                            </div>
                            <div class="bg-white p-2 border rounded shadow-sm">
                              <div class="text-gray-500">Total</div>
                              <div class="font-mono font-bold">{@usage["total_tokens"] || @usage[:total_tokens] || "-"}</div>
                            </div>
                         </div>
                      </div>
                    <% end %>
                  <% else %>
                    <div class="flex items-center justify-center h-full text-gray-400 italic">
                       Response will appear here...
                    </div>
                  <% end %>
               <% end %>
             </div>
          </div>

        </div>
      </div>
    </div>
    """
  end

  def handle_event("validate", params, socket) do
    # Handle hidden fields that might be missing from params
    custom_base_url = params["custom_base_url"] || socket.assigns.custom_base_url
    custom_adapter = params["custom_adapter"] || socket.assigns.custom_adapter
    new_mode = params["base_url_mode"]

    # Refresh models if mode changed
    models =
      if new_mode == socket.assigns.base_url_mode do
        socket.assigns.available_models
      else
        fetch_models(new_mode)
      end

    # Also update model if mode changed to first available (optional UX improvement)
    new_model =
      if new_mode == socket.assigns.base_url_mode do
        params["model"]
      else
        List.first(models) || params["model"]
      end

    new_config = %{
      api_key: params["api_key"],
      base_url_mode: new_mode,
      custom_base_url: custom_base_url,
      custom_adapter: custom_adapter,
      model: new_model,
      system_prompt: params["system_prompt"],
      user_prompt: params["user_prompt"],
      available_models: models
    }

    save_config(new_config)

    {:noreply, assign(socket, new_config)}
  end

  def handle_event("refresh_models", _params, socket) do
    mode = socket.assigns.base_url_mode
    models = fetch_models(mode)

    {:noreply,
     socket
     |> assign(available_models: models)
     |> add_log("Refreshed model list for #{mode}. Found #{length(models)} models.")}
  end

  def handle_event("run_request", _params, socket) do
    # Async request to not block UI?
    # For simplicity in this logical step, we'll do it in process,
    # but ideally we should use Task.async if it takes long.
    # Given we have one user, let's try Task.async

    parent = self()

    config = %{
      api_key: socket.assigns.api_key,
      base_url: get_base_url(socket.assigns.base_url_mode, socket.assigns.custom_base_url),
      base_url_mode: socket.assigns.base_url_mode,
      custom_adapter: socket.assigns.custom_adapter,
      model: socket.assigns.model,
      system_prompt: socket.assigns.system_prompt,
      user_prompt: socket.assigns.user_prompt
    }

    model_arg = resolve_model_arg(config)
    config = Map.put(config, :model_arg, model_arg)

    socket =
      socket
      |> assign(loading: true, error: nil, response: nil, usage: nil)
      |> add_log("--- New Request ---")
      |> add_log("Base URL: #{config.base_url}")
      |> add_log("Model Arg: #{model_arg}")
      |> add_log("Sending request...")

    Task.start(fn ->
      result = execute_request(config)
      send(parent, {:request_complete, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:request_complete, result}, socket) do
    socket = assign(socket, loading: false)

    case result do
      {:ok, response} ->
        # Handle content which might be a list of ContentParts now
        content =
          case response.message.content do
            parts when is_list(parts) ->
              Enum.map_join(parts, "\n", fn
                %ReqLLM.Message.ContentPart{text: text} -> text
                other -> inspect(other)
              end)

            text when is_binary(text) ->
              text

            other ->
              inspect(other)
          end

        usage = response.usage

        log_entry =
          if usage do
            "Success. In: #{usage["input_tokens"] || 0}, Out: #{usage["output_tokens"] || 0}, Total: #{usage["total_tokens"] || 0}"
          else
            "Success. No usage data."
          end

        socket
        |> assign(response: content, usage: usage)
        |> add_log(log_entry)
        |> noreply()

      {:error, reason} ->
        socket
        |> assign(error: inspect(reason, pretty: true))
        |> add_log("Request failed.")
        |> noreply()
    end
  end

  defp execute_request(config) do
    messages = [
      %{role: :system, content: config.system_prompt},
      %{role: :user, content: config.user_prompt}
    ]

    # Filter empty system prompt if strictly empty to avoid provider errors if any
    messages =
      if String.trim(config.system_prompt) == "",
        do: Enum.filter(messages, &(&1.role != :system)),
        else: messages

    model_arg = config.model_arg

    opts = [
      base_url: config.base_url,
      api_key: config.api_key,
      # 2 mins timeout
      receive_timeout: 120_000,
      max_tokens: 100
    ]

    # Remove nil/empty opts
    opts = Enum.reject(opts, fn {_, v} -> is_nil(v) || v == "" end)

    # Terminal Log (redact API key)
    IO.puts("\n>>> [ReqLLMPlayground] Executing Request")
    IO.puts("    Model: #{model_arg}")
    IO.puts("    BaseURL: #{config.base_url}")

    ReqLLM.generate_text(model_arg, messages, opts)
  end

  defp resolve_model_arg(config) do
    # Determine the target adapter based on the selected mode
    target_adapter =
      case config.base_url_mode do
        "openrouter" -> "openrouter"
        # Local usually implies OpenAI-compatible (Ollama, vLLM, etc)
        "local" -> "openai"
        "openai" -> "openai"
        "zenmux" -> "zenmux"
        "custom" -> config.custom_adapter
        _ -> "openai"
      end

    # Only prepend if not already present
    if String.starts_with?(config.model, target_adapter <> ":") do
      config.model
    else
      target_adapter <> ":" <> config.model
    end
  end

  defp fetch_models(mode) do
    # Filter based on mode
    provider_filter =
      case mode do
        "openrouter" -> :openrouter
        "openai" -> :openai
        # Fetch all? Or nothing? Let's fetch all for custom.
        "custom" -> nil
        "local" -> :local
        "zenmux" -> :zenmux
        _ -> :openrouter
      end

    models =
      cond do
        provider_filter == :local ->
          # LLMDB doesn't usually track local models. Fallback.
          []

        provider_filter ->
          LLMDB.models(provider_filter)

        true ->
          # Custom mode: fetch all models
          LLMDB.models()
      end

    # LLMDB.models/1 returns a list directly, not {:ok, list}
    if is_list(models) do
      models
      |> Enum.map(& &1.id)
      |> Enum.sort()
    else
      # Fallback if something unexpected happens
      []
    end
    |> then(fn list ->
      if provider_filter == :local && list == [] do
        ["llama3", "mistral", "gemma:2b"]
      else
        list
      end
    end)
  end

  defp get_base_url("openrouter", _), do: "https://openrouter.ai/api/v1"
  defp get_base_url("openai", _), do: "https://api.openai.com/v1"
  defp get_base_url("zenmux", _), do: "https://zenmux.ai/api/v1"
  defp get_base_url("local", _), do: "http://localhost:11434/v1"
  defp get_base_url("custom", custom), do: custom
  defp get_base_url(_, _), do: "https://openrouter.ai/api/v1"

  defp add_log(socket, msg) do
    update(socket, :logs, fn logs -> [%{msg: msg, time: DateTime.utc_now()} | logs] end)
  end

  defp noreply(socket), do: {:noreply, socket}

  # -- Persistence Helpers --

  defp config_file, do: "playground_config.json"

  defp load_config do
    case File.read(config_file()) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, data} -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_config(config) do
    # Don't persist API key to disk for security
    config_without_secrets = Map.delete(config, :api_key) |> Map.delete("api_key")
    File.write(config_file(), JSON.encode!(config_without_secrets))
  end
end

PhoenixPlayground.start(live: ReqLLMPlaygroundLive, port: 4001)
