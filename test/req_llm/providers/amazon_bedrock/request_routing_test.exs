defmodule ReqLLM.Providers.AmazonBedrock.RequestRoutingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock}

  @arn "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abcdef123456"
  @encoded_arn "arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Aapplication-inference-profile%2Fabcdef123456"

  describe "attach/3 Finch pool routing" do
    test "routes chat requests to the configured Finch pool" do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1"
      ]

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.options[:finch] == [name: ReqLLM.Application.finch_name()]
    end
  end

  describe "application inference profile ARNs" do
    setup do
      {:ok, model} = ReqLLM.model(%{provider: :amazon_bedrock, id: @arn})
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1"
      ]

      {:ok, model: model, context: context, opts: opts}
    end

    test "routes through the Converse API as one encoded path segment", %{
      model: model,
      context: context,
      opts: opts
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.path == "/model/#{@encoded_arn}/converse"
      assert request.options[:use_converse] == true
      assert %{"messages" => [%{"role" => "user"}]} = Jason.decode!(request.body)
    end

    test "streams through converse-stream", %{model: model, context: context, opts: opts} do
      {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert finch_request.path == "/model/#{@encoded_arn}/converse-stream"
    end

    test "leaves other model ids unencoded", %{context: context, opts: opts} do
      {:ok, model} = ReqLLM.model("amazon-bedrock:us.anthropic.claude-3-haiku-20240307-v1:0")
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.path == "/model/us.anthropic.claude-3-haiku-20240307-v1:0/invoke"
    end
  end

  describe "inference_profile_arn option" do
    setup do
      {:ok, model} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "us-east-1",
        provider_options: [inference_profile_arn: @arn]
      ]

      {:ok, model: model, context: context, opts: opts}
    end

    test "calls the profile while the model keeps its family and pricing", %{
      model: model,
      context: context,
      opts: opts
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.path == "/model/#{@encoded_arn}/invoke"
      assert request.options[:model] == "anthropic.claude-3-haiku-20240307-v1:0"
      assert request.options[:model_family] == "anthropic"
    end

    test "takes the Converse API through the profile", %{
      model: model,
      context: context,
      opts: opts
    } do
      opts = Keyword.update!(opts, :provider_options, &Keyword.put(&1, :use_converse, true))
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.path == "/model/#{@encoded_arn}/converse"
    end

    test "streams through the profile", %{model: model, context: context, opts: opts} do
      {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      assert finch_request.path == "/model/#{@encoded_arn}/invoke-with-response-stream"
    end

    test "names the likely cause of a native 400 through the profile", %{
      model: model,
      context: context,
      opts: opts
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      rejected = %Req.Response{
        status: 400,
        body: %{"message" => "Malformed input request: 4 schema violations found"}
      }

      {_request, error} = AmazonBedrock.decode_response({request, rejected})

      assert %ReqLLM.Error.API.Response{status: 400} = error
      assert error.reason =~ "built in anthropic.claude-3-haiku-20240307-v1:0's native format"
      assert error.reason =~ "the profile serves another model"
    end

    test "leaves a Converse 400 and a profile-less 400 alone", %{
      model: model,
      context: context,
      opts: opts
    } do
      rejected = %Req.Response{status: 400, body: %{"message" => "Malformed input request"}}
      converse = Keyword.update!(opts, :provider_options, &Keyword.put(&1, :use_converse, true))

      for opts <- [converse, Keyword.delete(opts, :provider_options)] do
        {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
        {_request, error} = AmazonBedrock.decode_response({request, rejected})

        assert error.reason == "Bedrock API error"
      end
    end

    test "embeds through the profile", %{opts: opts} do
      {:ok, model} = ReqLLM.model("amazon-bedrock:cohere.embed-english-v3")
      {:ok, request} = AmazonBedrock.prepare_request(:embedding, model, "Hello", opts)

      assert request.url.path == "/model/#{@encoded_arn}/invoke"
    end
  end
end
