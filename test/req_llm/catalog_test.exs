defmodule ReqLLM.CatalogTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Catalog

  @sample_base_catalog ReqLLM.Catalog.Base.base()

  setup do
    :ok
  end

  describe "load/1 with empty config" do
    test "returns error when allow is empty in non-test env" do
      config = [allow: %{}, overrides: [], custom: []]

      if Mix.env() == :test do
        assert {:ok, catalog} = Catalog.load(config)
        assert is_map(catalog)
      else
        assert {:error, reason} = Catalog.load(config)
        assert reason =~ "catalog.allow cannot be empty"
      end
    end

    test "succeeds with empty allow in test environment" do
      config = [allow: %{}, overrides: [], custom: []]

      assert {:ok, catalog} = Catalog.load(config)
      assert catalog == @sample_base_catalog
    end
  end

  describe "allowlist filtering" do
    test "filters models by provider allowlist" do
      config = [
        allow: %{
          openai: ["gpt-4o"],
          anthropic: ["claude-3-5-haiku-20241022"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.keys(catalog) |> Enum.sort() == ["anthropic", "openai"]
      assert Map.keys(catalog["openai"]["models"]) == ["gpt-4o"]
      assert Map.keys(catalog["anthropic"]["models"]) == ["claude-3-5-haiku-20241022"]
    end

    test "excludes providers not in allowlist" do
      config = [
        allow: %{
          openai: ["gpt-4o-mini"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.keys(catalog) == ["openai"]
      refute Map.has_key?(catalog, "anthropic")
    end

    test "handles atom keys in allowlist" do
      config = [
        allow: %{
          openai: ["gpt-4o"],
          anthropic: ["claude-3-5-sonnet-20241022"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.has_key?(catalog, "openai")
      assert Map.has_key?(catalog, "anthropic")
    end

    test "handles mixed atom and string model IDs" do
      config = [
        allow: %{
          "openai" => [:gpt_4o, "gpt-4o-mini"],
          :anthropic => ["claude-3-5-haiku-20241022"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      openai_models = Map.keys(catalog["openai"]["models"]) |> Enum.sort()
      assert openai_models == ["gpt-4o-mini"]
    end

    test "returns empty provider when no models match allowlist" do
      config = [
        allow: %{
          openai: ["nonexistent-model"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["models"] == %{}
    end
  end

  describe "custom providers merge" do
    test "adds custom provider with models" do
      config = [
        allow: %{
          openai: ["gpt-4o"],
          vllm: ["llama-3.2-3b-instruct"]
        },
        custom: [
          %{
            provider: %{
              id: "vllm",
              name: "vLLM",
              base_url: "http://localhost:8000",
              env: []
            },
            models: [
              %{
                id: "llama-3.2-3b-instruct",
                name: "LLaMA 3.2 3B Instruct",
                modalities: %{"input" => ["text"], "output" => ["text"]},
                limit: %{"context" => 8192},
                cost: %{"input" => 0.0, "output" => 0.0}
              }
            ]
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.has_key?(catalog, "vllm")
      assert catalog["vllm"]["name"] == "vLLM"
      assert catalog["vllm"]["base_url"] == "http://localhost:8000"
      assert Map.has_key?(catalog["vllm"]["models"], "llama-3.2-3b-instruct")
    end

    test "handles atom keys in custom provider" do
      config = [
        allow: %{
          llamacpp: ["qwen2.5-7b-instruct-q4"]
        },
        custom: [
          %{
            provider: %{
              id: :llamacpp,
              name: "LLaMA CPP",
              base_url: "http://localhost:8080",
              env: []
            },
            models: [
              %{
                id: "qwen2.5-7b-instruct-q4",
                name: "Qwen 2.5 7B Instruct Q4",
                cost: %{input: 0.0, output: 0.0}
              }
            ]
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.has_key?(catalog, "llamacpp")
      assert catalog["llamacpp"]["name"] == "LLaMA CPP"
    end

    test "custom provider replaces base provider with same ID" do
      config = [
        allow: %{
          openai: ["custom-gpt"]
        },
        custom: [
          %{
            provider: %{
              id: "openai",
              name: "Custom OpenAI",
              base_url: "http://custom.openai.local",
              env: []
            },
            models: [
              %{
                id: "custom-gpt",
                name: "Custom GPT",
                cost: %{"input" => 0.0, "output" => 0.0}
              }
            ]
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["name"] == "Custom OpenAI"
      assert catalog["openai"]["base_url"] == "http://custom.openai.local"
      assert Map.has_key?(catalog["openai"]["models"], "custom-gpt")
      refute Map.has_key?(catalog["openai"]["models"], "gpt-4o")
    end

    test "normalizes keys in custom providers and models" do
      config = [
        allow: %{
          vllm: ["test-model"]
        },
        custom: [
          %{
            "provider" => %{
              "id" => "vllm",
              "name" => "vLLM"
            },
            "models" => [
              %{
                "id" => "test-model",
                "name" => "Test Model"
              }
            ]
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["vllm"]["id"] == "vllm"
      assert catalog["vllm"]["models"]["test-model"]["name"] == "Test Model"
    end
  end

  describe "overrides application" do
    test "applies provider-level overrides" do
      config = [
        allow: %{
          openai: ["gpt-4o"]
        },
        overrides: [
          providers: %{
            openai: %{
              "base_url" => "https://custom.openai.com/v1"
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["base_url"] == "https://custom.openai.com/v1"
      assert catalog["openai"]["name"] == "OpenAI"
    end

    test "applies model-level overrides" do
      config = [
        allow: %{
          openai: ["gpt-4o-mini"]
        },
        overrides: [
          models: %{
            openai: %{
              "gpt-4o-mini" => %{
                "cost" => %{
                  "input" => 0.00015,
                  "output" => 0.0006
                }
              }
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      model = catalog["openai"]["models"]["gpt-4o-mini"]
      assert model["cost"]["input"] == 0.00015
      assert model["cost"]["output"] == 0.0006
      assert model["limit"]["context"] == 128_000
    end

    test "deep merges nested override maps" do
      config = [
        allow: %{
          anthropic: ["claude-3-5-haiku-20241022"]
        },
        overrides: [
          models: %{
            anthropic: %{
              "claude-3-5-haiku-20241022" => %{
                "cost" => %{
                  "input" => 3.5
                }
              }
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      model = catalog["anthropic"]["models"]["claude-3-5-haiku-20241022"]
      assert model["cost"]["input"] == 3.5
      assert model["cost"]["output"] == 4
    end

    test "provider overrides cannot touch models key" do
      config = [
        allow: %{
          openai: ["gpt-4o"]
        },
        overrides: [
          providers: %{
            openai: %{
              "base_url" => "https://custom.openai.com",
              "models" => %{}
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["base_url"] == "https://custom.openai.com"
      assert Map.has_key?(catalog["openai"]["models"], "gpt-4o")
      refute catalog["openai"]["models"] == %{}
    end

    test "handles atom keys in overrides" do
      config = [
        allow: %{
          openai: ["gpt-4o"]
        },
        overrides: [
          providers: %{
            openai: %{
              base_url: "https://custom.openai.com"
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["base_url"] == "https://custom.openai.com"
    end
  end

  describe "key normalization" do
    test "normalizes all atom keys to strings" do
      config = [
        allow: %{
          openai: ["gpt-4o"]
        }
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert is_binary(hd(Map.keys(catalog)))

      Enum.each(catalog, fn {_provider_id, provider} ->
        assert Enum.all?(Map.keys(provider), &is_binary/1)

        Enum.each(provider["models"], fn {_model_id, model} ->
          assert Enum.all?(Map.keys(model), &is_binary/1)
        end)
      end)
    end

    test "normalizes mixed atom and string keys" do
      config = [
        allow: %{
          "openai" => ["gpt-4o"],
          anthropic: ["claude-3-5-haiku-20241022"]
        },
        overrides: [
          providers: %{
            "openai" => %{base_url: "https://custom1.com"},
            "anthropic" => %{"base_url" => "https://custom2.com"}
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert catalog["openai"]["base_url"] == "https://custom1.com"
      assert catalog["anthropic"]["base_url"] == "https://custom2.com"
    end
  end

  describe "config validation" do
    test "returns error for invalid config structure" do
      config = [
        allow: "not a map",
        overrides: [],
        custom: []
      ]

      assert {:error, reason} = Catalog.load(config)
      assert is_binary(reason)
    end

    test "returns error for invalid overrides structure" do
      config = [
        allow: %{openai: ["gpt-4o"]},
        overrides: "not a keyword list",
        custom: []
      ]

      assert {:error, reason} = Catalog.load(config)
      assert is_binary(reason)
    end

    test "returns error for invalid custom structure" do
      config = [
        allow: %{openai: ["gpt-4o"]},
        overrides: [],
        custom: "not a list"
      ]

      assert {:error, reason} = Catalog.load(config)
      assert is_binary(reason)
    end
  end

  describe "load/0 with Application config" do
    setup do
      original_config = Application.get_env(:req_llm, :catalog)

      on_exit(fn ->
        if original_config do
          Application.put_env(:req_llm, :catalog, original_config)
        else
          Application.delete_env(:req_llm, :catalog)
        end
      end)

      :ok
    end

    test "reads configuration from Application environment" do
      Application.put_env(:req_llm, :catalog,
        allow: %{openai: ["gpt-4o"]},
        overrides: [],
        custom: []
      )

      assert {:ok, catalog} = Catalog.load()
      assert Map.has_key?(catalog, "openai")
      assert Map.keys(catalog["openai"]["models"]) == ["gpt-4o"]
    end

    test "uses empty config when not configured" do
      Application.delete_env(:req_llm, :catalog)

      if Mix.env() == :test do
        assert {:ok, catalog} = Catalog.load()
        assert is_map(catalog)
      else
        assert {:error, reason} = Catalog.load()
        assert reason =~ "catalog.allow cannot be empty"
      end
    end
  end

  describe "integration scenarios" do
    test "full pipeline: custom + allow + overrides" do
      config = [
        allow: %{
          openai: ["gpt-4o-mini"],
          vllm: ["llama-3.2-3b-instruct"]
        },
        custom: [
          %{
            provider: %{
              id: "vllm",
              name: "vLLM",
              base_url: "http://localhost:8000",
              env: []
            },
            models: [
              %{
                id: "llama-3.2-3b-instruct",
                name: "LLaMA 3.2 3B",
                cost: %{"input" => 0.0, "output" => 0.0}
              }
            ]
          }
        ],
        overrides: [
          providers: %{
            openai: %{"base_url" => "https://custom.openai.com"}
          },
          models: %{
            openai: %{
              "gpt-4o-mini" => %{
                "cost" => %{"input" => 0.0001}
              }
            }
          }
        ]
      ]

      assert {:ok, catalog} = Catalog.load(config)

      assert Map.keys(catalog) |> Enum.sort() == ["openai", "vllm"]

      assert catalog["openai"]["base_url"] == "https://custom.openai.com"
      assert catalog["openai"]["models"]["gpt-4o-mini"]["cost"]["input"] == 0.0001

      assert catalog["vllm"]["name"] == "vLLM"
      assert catalog["vllm"]["base_url"] == "http://localhost:8000"
      assert Map.has_key?(catalog["vllm"]["models"], "llama-3.2-3b-instruct")
    end
  end
end
