defmodule ReqLLM.Router.TrieTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Router.Trie

  test "orders exact, single wildcard, and multi wildcard routes" do
    trie =
      Trie.new!([
        {"chat.code", :exact},
        {"chat.*", :single},
        {"chat.**", :multi},
        {"**", :fallback}
      ])

    assert {:ok, [:exact, :single, :multi, :fallback]} =
             Trie.route(trie, "chat.code", %{})
  end

  test "guards select routes using the routed value" do
    high? = fn request -> request.complexity == :high end
    low? = fn request -> request.complexity == :low end

    trie =
      Trie.new!([
        {"chat", high?, :large, 10},
        {"chat", low?, :small, 10},
        {"chat", :default, -10}
      ])

    assert {:ok, [:large, :default]} = Trie.route(trie, "chat", %{complexity: :high})
    assert {:ok, [:small, :default]} = Trie.route(trie, "chat", %{complexity: :low})
  end

  test "uses priority and registration order after path specificity" do
    trie =
      Trie.new!([
        {"chat", :first, 10},
        {"chat", :second, 10},
        {"chat", :highest, 20},
        {"*", :wildcard, 100}
      ])

    assert {:ok, [:highest, :first, :second, :wildcard]} =
             Trie.route(trie, "chat", nil)
  end

  test "a guard failure does not stop other matching routes" do
    trie =
      Trie.new!([
        {"chat", fn _request -> raise "failed" end, :broken},
        {"chat", :default}
      ])

    assert {:ok, [:default]} = Trie.route(trie, "chat", %{})
  end

  test "returns an error when no route matches" do
    trie = Trie.new!([{"object", :model}])

    assert {:error, error} = Trie.route(trie, "chat", %{})
    assert Exception.message(error) =~ "no router route matched"
  end

  test "validates paths, guards, and priorities" do
    assert {:error, _error} = Trie.new([{"chat..code", :model}])
    assert {:error, _error} = Trie.new([{"chat", :model, 101}])

    assert {:error, _error} =
             Trie.new([%Trie.Route{path: "chat", target: :model, guard: :invalid}])
  end
end
