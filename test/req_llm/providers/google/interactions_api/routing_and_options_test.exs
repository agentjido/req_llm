defmodule ReqLLM.Providers.Google.InteractionsAPI.RoutingAndOptionsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Tool

  @model_id "google:gemini-4-hydrogen"
  @api_key "test-google-key"

  describe "mode resolution and endpoint routing" do
    test "defaults to generateContent and routes to /v1/interactions on google_api: :interactions" do
      {:ok, gc_req} = Google.prepare_request(:chat, @model_id, "Hello", api_key: @api_key)
      assert gc_req.url.path == "/models/gemini-4-hydrogen:generateContent"
      assert gc_req.options[:base_url] == "https://generativelanguage.googleapis.com/v1beta"

      {:ok, int_req} =
        Google.prepare_request(:chat, @model_id, "Hello",
          api_key: @api_key,
          google_api: :interactions
        )

      assert int_req.url.path == "/interactions"
      assert int_req.options[:base_url] == "https://generativelanguage.googleapis.com/v1"
      assert int_req.options[:google_api_type] == :interactions
      assert Req.Request.get_header(int_req, "api-revision") == ["2026-05-20"]
      assert Req.Request.get_header(int_req, "x-goog-api-key") == [@api_key]
    end

    test "auto-routes to Interactions API when Interactions-only options are present" do
      for opt <- [
            [agent: "deep-research-pro-preview-12-2025"],
            [previous_interaction_id: "v1_prev_123"],
            [background: true],
            [store: false],
            [service_tier: :priority],
            [continuation_token: "tok_1"],
            [google_code_execution: true],
            [google_search_types: ["web_search"]],
            [google_file_search: %{file_search_store_names: ["fileSearchStores/s1"]}],
            [google_mcp_servers: [%{name: "linear", url: "https://mcp.example.com"}]],
            [labels: %{"env" => "prod"}],
            [provider_options: [previous_interaction_id: "v1_prev_nested"]]
          ] do
        {:ok, req} =
          Google.prepare_request(
            :chat,
            @model_id,
            "Continue",
            Keyword.put(opt, :api_key, @api_key)
          )

        assert req.url.path == "/interactions"
        assert req.options[:google_api_type] == :interactions
      end
    end

    test "resolves map provider_options for Interactions routing and effective_base_url" do
      assert InteractionsAPI.effective_base_url(
               base_url: "https://generativelanguage.googleapis.com/"
             ) == "https://generativelanguage.googleapis.com/v1"

      assert InteractionsAPI.effective_base_url(
               base_url: "https://generativelanguage.googleapis.com/v1beta/"
             ) == "https://generativelanguage.googleapis.com/v1beta"

      {:ok, map_opts_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Hi",
          api_key: @api_key,
          reasoning_effort: :medium,
          provider_options: %{google_api: :interactions}
        )

      assert map_opts_req.options[:google_api_type] == :interactions
    end

    test "defaults to v1beta for agents, allows v1 with tools/grounding, preserves custom base_url, and supports query auth" do
      {:ok, agent_req} =
        Google.prepare_request(:chat, @model_id, "Research",
          api_key: @api_key,
          agent: "deep-research-pro-preview-12-2025"
        )

      assert agent_req.options[:base_url] == "https://generativelanguage.googleapis.com/v1beta"

      tool =
        Tool.new!(
          name: "lookup",
          description: "Look up data",
          parameter_schema: [q: [type: :string, required: true]],
          callback: fn _ -> {:ok, "done"} end
        )

      {:ok, tools_v1_req} =
        Google.prepare_request(:chat, @model_id, "Search",
          api_key: @api_key,
          google_api: :interactions,
          tools: [tool],
          provider_options: [google_grounding: %{enable: true}]
        )

      assert tools_v1_req.options[:base_url] == "https://generativelanguage.googleapis.com/v1"

      {:ok, override_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions,
          provider_options: [google_api_version: "v1beta"]
        )

      assert override_req.options[:base_url] == "https://generativelanguage.googleapis.com/v1beta"

      {:ok, proxy_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          google_api: :interactions,
          base_url: "http://litellm.local:4000/",
          provider_options: [google_auth_header: false]
        )

      assert proxy_req.options[:base_url] == "http://litellm.local:4000"
      assert proxy_req.options[:params] == [key: @api_key]
      assert Req.Request.get_header(proxy_req, "x-goog-api-key") == []
    end

    test "isolates embedding and image operations from Interactions routing" do
      assert {:error, %Parameter{}} =
               Google.prepare_request(:embedding, "google:gemini-embedding-001", "hi",
                 api_key: @api_key,
                 google_api: :interactions
               )

      assert {:ok, img_req} =
               Google.prepare_request(
                 :image,
                 %{provider: :google, id: "imagen-3.0-generate-002"},
                 "a cat",
                 api_key: @api_key,
                 response_format: :url
               )

      img_encoded = Google.encode_body(img_req).options[:json]
      assert Map.has_key?(img_encoded, :instances)
      refute Map.has_key?(img_encoded, "input")

      for bad_opts <- [
            [provider_options: %{google_api: :interactions}],
            [agent: "deep-research-pro-preview-12-2025"],
            [previous_interaction_id: "int_1"],
            [background: true],
            [labels: %{"env" => "prod"}]
          ] do
        assert {:error, %Parameter{}} =
                 Google.prepare_request(
                   :embedding,
                   "google:gemini-embedding-001",
                   "hi",
                   [{:api_key, @api_key} | bad_opts]
                 )

        assert {:error, %Parameter{}} =
                 Google.prepare_request(
                   :image,
                   %{provider: :google, id: "imagen-3.0-generate-002"},
                   "a cat",
                   [{:api_key, @api_key} | bad_opts]
                 )
      end
    end
  end

  describe "option validation" do
    test "rejects conflicting google_api and store option combinations" do
      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hello",
                 api_key: @api_key,
                 google_api: :generate_content,
                 agent: "deep-research-pro-preview-12-2025"
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hello",
                 api_key: @api_key,
                 google_api: :generate_content,
                 previous_interaction_id: "int_1"
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hello",
                 api_key: @api_key,
                 google_api: :generate_content,
                 interactions_resume_id: "int_resume"
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hello",
                 api_key: @api_key,
                 store: false,
                 previous_interaction_id: "int_1"
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hello",
                 api_key: @api_key,
                 store: false,
                 background: true
               )

      assert {:error, %Parameter{}} =
               InteractionsAPI.validate_options(%{store: false, background: true})

      assert {:error, %Parameter{}} =
               InteractionsAPI.validate_options(%{
                 provider_options: %{store: false, previous_interaction_id: "int_1"}
               })

      assert {:ok, :interactions} =
               InteractionsAPI.resolve_mode(%{provider_options: %{store: false}})

      map_req = %Req.Request{
        options: %{
          model: "gemini-4-hydrogen",
          context: Context.new([Context.user("Hi")]),
          google_api: :interactions,
          provider_options: %{store: false, background: false, google_include_thoughts: false}
        },
        private: %{}
      }

      map_body = InteractionsAPI.encode_body(map_req).options[:json]
      assert map_body["store"] == false
      assert map_body["background"] == false
      assert map_body["generation_config"]["thinking_summaries"] == "none"
    end

    test "allows response_format on generate_content chat and rejects labels/response_format with explicit generate_content" do
      {:ok, chat_rf_req} =
        Google.prepare_request(:chat, @model_id, "Hi",
          api_key: @api_key,
          response_format: %{type: "json_object"}
        )

      assert chat_rf_req.url.path == "/models/gemini-4-hydrogen:generateContent"

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hi",
                 api_key: @api_key,
                 google_api: :generate_content,
                 labels: %{"env" => "prod"}
               )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, @model_id, "Hi",
                 api_key: @api_key,
                 google_api: :generate_content,
                 response_format: %{"type" => "text"}
               )
    end

    test "rejects :object with tools on pre-Gemini-3 models across buffered and streaming paths" do
      {:ok, model_25} = ReqLLM.model("google:gemini-2.5-flash")
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      tool =
        Tool.new!(
          name: "lookup",
          description: "Lookup",
          parameter_schema: [q: [type: :string, required: true]],
          callback: fn _ -> {:ok, "done"} end
        )

      assert {:error, %Parameter{}} =
               Google.prepare_request(:object, "google:gemini-2.5-flash", "Extract",
                 api_key: @api_key,
                 google_api: :interactions,
                 compiled_schema: schema,
                 tools: [tool]
               )

      assert {:error, %Parameter{}} =
               Google.attach_stream(
                 model_25,
                 Context.new([Context.user("Extract")]),
                 [
                   api_key: @api_key,
                   operation: :object,
                   google_api: :interactions,
                   compiled_schema: schema,
                   tools: [tool]
                 ],
                 :default
               )
    end
  end

  describe "reasoning effort and thinking compatibility" do
    test "maps reasoning_effort including :xhigh for gemini-4 and uses thinking_level on Interactions for gemini-2.5" do
      {:ok, h_req} =
        Google.prepare_request(:chat, "google:gemini-4-hydrogen", "Reason",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :xhigh
        )

      encoded_h = Google.encode_body(h_req)
      assert encoded_h.options[:json]["generation_config"]["thinking_level"] == "xhigh"

      {:ok, c_req} =
        Google.prepare_request(:chat, "google:gemini-4-carbon", "Reason",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :xhigh
        )

      encoded_c = Google.encode_body(c_req)
      assert encoded_c.options[:json]["generation_config"]["thinking_level"] == "high"

      {:ok, g25_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Reason",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :medium,
          temperature: 0.3
        )

      encoded_g25 = Google.encode_body(g25_req)
      assert encoded_g25.options[:json]["generation_config"]["thinking_level"] == "medium"
      assert encoded_g25.options[:json]["generation_config"]["temperature"] == 0.3
      refute Map.has_key?(encoded_g25.options[:json]["generation_config"], "thinking_budget")

      {:ok, g25_explicit_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Reason",
          api_key: @api_key,
          google_api: :interactions,
          top_k: 32,
          reasoning_token_budget: 2048
        )

      encoded_g25_budget = Google.encode_body(g25_explicit_req).options[:json]
      assert encoded_g25_budget["generation_config"]["top_k"] == 32
      assert encoded_g25_budget["generation_config"]["thinking_budget"] == 2048
      assert encoded_g25_budget["generation_config"]["thinking_summaries"] == "auto"

      {:ok, g25_level_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Reason",
          api_key: @api_key,
          google_api: :interactions,
          provider_options: [google_thinking_level: :medium]
        )

      encoded_g25_level = Google.encode_body(g25_level_req).options[:json]
      assert encoded_g25_level["generation_config"]["thinking_level"] == "medium"
    end

    test "clamps and rejects :xhigh on non-Hydrogen models and preserves colon-suffixed model IDs" do
      {:ok, g25_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Hi",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :xhigh
        )

      assert Google.encode_body(g25_req).options[:json]["generation_config"]["thinking_level"] ==
               "high"

      for model_spec <- [
            "google:gemini-2.5-flash",
            "google:gemini-3-flash-preview",
            "google:gemini-4-carbon"
          ] do
        assert {:error, %Parameter{}} =
                 Google.prepare_request(:chat, model_spec, "Hi",
                   api_key: @api_key,
                   google_api: :interactions,
                   provider_options: [google_thinking_level: :xhigh]
                 )
      end

      for model_spec <- [
            %LLMDB.Model{provider: :google, id: "gemini-4-custom"},
            %LLMDB.Model{provider: :google, id: "tunedModels/custom:v2"},
            %LLMDB.Model{provider: :google, id: "gemini-5-preview"}
          ] do
        {:ok, xhigh_req} =
          Google.prepare_request(:chat, model_spec, "Hi",
            api_key: @api_key,
            google_api: :interactions,
            provider_options: [google_thinking_level: :xhigh]
          )

        assert Google.encode_body(xhigh_req).options[:json]["generation_config"][
                 "thinking_level"
               ] == "xhigh"
      end

      assert {:error, %Parameter{}} =
               Google.prepare_request(
                 :chat,
                 %LLMDB.Model{provider: :google, id: "gemini-3.8-flash:001"},
                 "Hi",
                 api_key: @api_key,
                 google_api: :interactions,
                 provider_options: [google_thinking_level: :minimal]
               )

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(
          "google:gemini-2.5-flash",
          Context.new([Context.user("Hi")]),
          google_thinking_level: :xhigh
        )
      end

      for {input_id, expected} <- [
            {"models/gemini-2.5-flash:001", "gemini-2.5-flash:001"},
            {"tunedModels/custom:v2", "tunedModels/custom:v2"},
            {"gemini-2.5-flash:latest", "gemini-2.5-flash:latest"},
            {"google:models/gemini-2.5-flash:001", "gemini-2.5-flash:001"}
          ] do
        body =
          InteractionsAPI.build_request_body(
            input_id,
            Context.new([Context.user("Hi")]),
            google_api: :interactions
          )

        assert body["model"] == expected
      end

      assert_raise Parameter, fn ->
        InteractionsAPI.build_request_body(nil, Context.new([Context.user("Hi")]), [])
      end
    end

    test "rejects combined google_thinking_budget and google_thinking_level and maps :none effort" do
      {:ok, model_25} = ReqLLM.model("google:gemini-2.5-flash")

      assert {:error, %Parameter{}} =
               Google.prepare_request(:chat, "google:gemini-2.5-flash", "Hi",
                 api_key: @api_key,
                 google_api: :interactions,
                 google_thinking_budget: 1024,
                 google_thinking_level: :medium
               )

      assert {:error, %Parameter{}} =
               Google.attach_stream(
                 model_25,
                 Context.new([Context.user("Hi")]),
                 [
                   api_key: @api_key,
                   google_api: :interactions,
                   google_thinking_budget: 1024,
                   google_thinking_level: :medium
                 ],
                 :default
               )

      {:ok, budget_effort_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Hi",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :medium,
          provider_options: [google_thinking_budget: 2048]
        )

      budget_body = Google.encode_body(budget_effort_req).options[:json]
      assert budget_body["generation_config"]["thinking_budget"] == 2048
      refute Map.has_key?(budget_body["generation_config"], "thinking_level")

      {:ok, pro_none_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-pro", "Hi",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :none
        )

      pro_none_body = Google.encode_body(pro_none_req).options[:json]
      assert pro_none_body["generation_config"]["thinking_level"] == "low"

      {:ok, flash_none_req} =
        Google.prepare_request(:chat, "google:gemini-2.5-flash", "Hi",
          api_key: @api_key,
          google_api: :interactions,
          reasoning_effort: :none
        )

      flash_none_body = Google.encode_body(flash_none_req).options[:json]
      assert flash_none_body["generation_config"]["thinking_level"] == "minimal"
      refute Map.has_key?(flash_none_body["generation_config"], "thinking_summaries")
    end
  end
end
