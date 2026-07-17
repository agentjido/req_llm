defmodule ReqLLM.MigrationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Migration

  setup do
    directory =
      Path.join(System.tmp_dir!(), "req-llm-migration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{directory: directory}
  end

  test "ships a valid JSON ledger with unique owned records" do
    assert :ok = Migration.validate_ledger()

    ledger = Migration.ledger()
    records = ledger["deprecations"] ++ ledger["migration_checks"]

    assert ledger["schema_version"] == 1
    assert length(records) == length(Enum.uniq_by(records, & &1["id"]))
    assert Enum.all?(records, &is_binary(&1["owner"]))
    assert Enum.all?(records, &is_binary(&1["guide"]))
    assert Jason.decode!(Jason.encode!(ledger)) == ledger
  end

  test "keeps the approved removal set aligned with the V2 roadmap" do
    approved_deprecations =
      Migration.deprecations()
      |> Enum.filter(&(&1["v2_scope"] == "approved"))
      |> Enum.map(& &1["contract"])
      |> Enum.sort()

    assert approved_deprecations == [
             "ReqLLM.Generation.stream_object!/4",
             "ReqLLM.Generation.stream_text!/3",
             "ReqLLM.stream_object!/4",
             "ReqLLM.stream_text!/3"
           ]

    approved_checks =
      Migration.migration_checks()
      |> Enum.filter(&(&1["v2_scope"] == "approved"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert approved_checks == [
             "v2.implicit_output_validation",
             "v2.legacy_provider_options",
             "v2.provider_behaviour",
             "v2.raw_stream_field"
           ]
  end

  test "records every active compiled ReqLLM deprecation" do
    {:ok, modules} = :application.get_key(:req_llm, :modules)

    compiled_contracts =
      modules
      |> Enum.flat_map(&deprecated_contracts/1)
      |> Enum.sort()

    ledger_contracts =
      Migration.deprecations()
      |> Enum.map(& &1["contract"])
      |> Enum.sort()

    assert ledger_contracts == compiled_contracts
  end

  test "detects each precise migration pattern without evaluating source", %{directory: directory} do
    path = Path.join(directory, "sample.ex")

    File.write!(path, """
    defmodule Sample do
      @behaviour ReqLLM.Provider

      def run(value) do
        ReqLLM.stream_text!("openai:gpt-4o", "hello")

        ReqLLM.generate_text("openai:gpt-4o", "hello",
          provider_options: [store: false]
        )

        ReqLLM.generate_text("openai:gpt-4o", "hello",
          output: ReqLLM.Output.object(name: [type: :string])
        )

        case value do
          %ReqLLM.StreamResponse{stream: stream} -> stream
        end
      end
    end
    """)

    report = Migration.audit(directory)
    ids = Enum.map(report["findings"], & &1["id"])

    assert report["status"] == "findings"

    assert report["summary"] == %{
             "files_scanned" => 1,
             "actionable" => 4,
             "advisory" => 1,
             "errors" => 0
           }

    assert "req_llm.stream_text_bang" in ids
    assert "v2.legacy_provider_options" in ids
    assert "v2.raw_stream_field" in ids
    assert "v2.provider_behaviour" in ids
    assert "v2.implicit_output_validation" in ids
    assert Migration.exit_status(report) == 1
    assert Jason.encode!(report)
  end

  test "accepts namespaced options and explicit structured-output policy", %{directory: directory} do
    path = Path.join(directory, "clean.ex")

    File.write!(path, """
    defmodule Clean do
      def run do
        ReqLLM.generate_text("openai:gpt-4o", "hello",
          provider_options: [openai: [store: false]],
          output: ReqLLM.Output.object(name: [type: :string]),
          output_validation: :strict
        )
      end
    end
    """)

    report = Migration.audit(path)

    assert report["status"] == "clean"
    assert report["findings"] == []
    assert Migration.exit_status(report) == 0
  end

  test "reports provider extensions as non-failing advisories", %{directory: directory} do
    path = Path.join(directory, "provider.ex")

    File.write!(path, """
    defmodule CustomProvider do
      use ReqLLM.Provider, id: :custom_provider
    end
    """)

    report = Migration.audit(path)

    assert report["status"] == "advisory"
    assert report["summary"]["advisory"] == 1
    assert report["summary"]["actionable"] == 0
    assert Migration.exit_status(report) == 0
  end

  test "reports unapproved deprecations without blocking V2 readiness", %{directory: directory} do
    path = Path.join(directory, "unapproved.ex")

    File.write!(path, """
    defmodule UnapprovedDeprecation do
      def run, do: ReqLLM.Keys.fetch(:openai)
    end
    """)

    report = Migration.audit(path)
    finding = hd(report["findings"])

    assert report["status"] == "advisory"
    assert report["summary"]["actionable"] == 0
    assert report["summary"]["advisory"] == 1
    assert finding["id"] == "req_llm.keys.fetch"
    assert finding["actionable"] == false
    assert finding["message"] =~ "not approved for removal in V2"
    assert Migration.exit_status(report) == 0
  end

  test "detects every ledger-backed deprecated remote call", %{directory: directory} do
    path = Path.join(directory, "deprecated.ex")

    calls =
      Enum.map_join(Migration.deprecations(), "\n", fn entry ->
        detector = entry["detector"]
        "#{detector["module"]}.#{detector["function"]}()"
      end)

    File.write!(path, "defmodule DeprecatedCalls do\n  def run do\n#{calls}\n  end\nend\n")

    report = Migration.audit(path)

    detected_ids =
      report["findings"]
      |> Enum.filter(&(&1["category"] == "deprecated_api"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    ledger_ids = Migration.deprecations() |> Enum.map(& &1["id"]) |> Enum.sort()

    assert detected_ids == ledger_ids

    assert report["summary"]["actionable"] == 4
    assert report["summary"]["advisory"] == 11
  end

  test "ignores dynamic migration shapes it cannot prove", %{directory: directory} do
    path = Path.join(directory, "dynamic.ex")

    File.write!(path, """
    defmodule Dynamic do
      def run(model, options, output) do
        ReqLLM.generate_text(model, "hello", options)
        ReqLLM.generate_text("openai:gpt-4o", "hello", output: output)
        ReqLLM.generate_text("openai:gpt-4o", "hello", provider_options: options)
        ReqLLM.generate_text("openai:gpt-4o", "hello", provider_options: %{output => true})
        __MODULE__.Helpers.run()
      end
    end
    """)

    report = Migration.audit(path)

    assert report["status"] == "clean"
    assert report["findings"] == []
  end

  test "does not change audited files or create artifacts", %{directory: directory} do
    path = Path.join(directory, "read_only.ex")
    body = "defmodule ReadOnly do\n  def run, do: :ok\nend\n"
    File.write!(path, body)
    entries_before = File.ls!(directory)
    stat_before = File.stat!(path)

    report = Migration.audit(directory)

    assert report["status"] == "clean"
    assert File.read!(path) == body
    assert File.ls!(directory) == entries_before
    assert File.stat!(path).mtime == stat_before.mtime
  end

  test "reports parse and path failures with exit status 2", %{directory: directory} do
    invalid_path = Path.join(directory, "invalid.ex")
    missing_path = Path.join(directory, "missing")
    File.write!(invalid_path, "defmodule Invalid do")

    report = Migration.audit([invalid_path, missing_path])

    assert report["status"] == "error"
    assert report["summary"]["errors"] == 2
    assert Migration.exit_status(report) == 2
  end

  test "returns machine-readable errors for invalid public API input" do
    invalid_options = Migration.audit(".", ["invalid"])
    invalid_paths = Migration.audit([:invalid])

    assert invalid_options["status"] == "error"
    assert invalid_paths["status"] == "error"
    assert invalid_options["summary"]["files_scanned"] == 0
    assert Migration.exit_status(invalid_options) == 2
    assert Jason.encode!(invalid_options)
  end

  test "honors explicit excluded paths", %{directory: directory} do
    included = Path.join(directory, "included.ex")
    excluded = Path.join(directory, "excluded")
    File.mkdir_p!(excluded)
    File.write!(included, "defmodule Included do\n  def run, do: :ok\nend\n")

    File.write!(
      Path.join(excluded, "deprecated.ex"),
      "defmodule Excluded do\n  def run, do: ReqLLM.stream_text!(\"openai:gpt-4o\", \"hi\")\nend\n"
    )

    report = Migration.audit(directory, exclude: excluded)

    assert report["status"] == "clean"
    assert report["summary"]["files_scanned"] == 1
  end

  defp deprecated_contracts(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, docs} ->
        Enum.flat_map(docs, fn
          {{:function, name, arity}, _, _, _, %{deprecated: _message}} ->
            ["#{inspect(module)}.#{name}/#{arity}"]

          _doc ->
            []
        end)

      _docs ->
        []
    end
  end
end
