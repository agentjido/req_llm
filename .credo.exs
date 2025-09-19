%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      requires: ["lib/credo/check/consistency/no_comments_in_function_bodies.ex"],
      strict: true,
      checks: [
        # Custom check to prevent comments in function bodies
        {Credo.Check.Consistency.NoCommentsInFunctionBodies, []}
      ]
    }
  ]
}
