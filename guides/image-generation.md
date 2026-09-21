# Image Generation

> **Interactive Demo:** An interactive Livebook version of this guide is available at `guides/image-generation.livemd`.

## Overview

ReqLLM provides image generation through the `ReqLLM.generate_image/3` function, which works similarly to `ReqLLM.generate_text/3`. The key difference is that the response contains image data instead of text.

### Basic Usage

```elixir
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1",
  "A serene Japanese garden with cherry blossoms"
)

# Extract the image binary data
image_data = ReqLLM.Response.image_data(response)

# Save to file
File.write!("garden.png", image_data)
```

### Response Structure

Image generation returns a canonical `ReqLLM.Response` struct where the assistant message contains `ReqLLM.Message.ContentPart` entries of type `:image` (binary data) or `:image_url` (URL reference).

```elixir
# Get the first image part
image_part = ReqLLM.Response.image(response)
# => #ContentPart<:image image/png (3469636 bytes)>

# Get all images (when n > 1)
all_images = ReqLLM.Response.images(response)

# Convenience helpers
binary_data = ReqLLM.Response.image_data(response)  # First :image part's data
url = ReqLLM.Response.image_url(response)           # First :image_url part's URL
```

## Common Options

These options are supported across providers (where the model allows):

| Option | Type | Description |
|--------|------|-------------|
| `n` | integer | Number of images to generate (provider-dependent; gemini-2.5-flash-image and gemini-3-pro-image-preview reject `n`) |
| `size` | string or tuple | Image dimensions, e.g., `"1024x1024"` or `{1024, 1024}` |
| `aspect_ratio` | string | Aspect ratio, e.g., `"16:9"` or `"1:1"` (on OpenAI and Azure this resolves to the nearest supported `size` — see below) |
| `output_format` | atom | Image format: `:png`, `:jpeg`, or `:webp` (Azure: `:png` and `:jpeg` only) |
| `response_format` | atom | Return type: `:binary` (default) or `:url` (URL responses are DALL-E only; on GPT Image `:url` is dropped with a warning, since those models always return bytes) |
| `quality` | atom/string | Image quality: `:auto`, `:low`, `:medium`, `:high` for GPT Image (`:xhigh`, `:max` on gpt-image-2.5); `:standard`, `:hd` for DALL-E 3 (translated with a warning on GPT Image) |
| `background` | atom/string | `:auto`, `:transparent`, or `:opaque`; `:transparent` needs `:png` or `:webp` output (GPT Image on OpenAI and Azure only) |
| `moderation` | atom/string | `:auto` or `:low`; generations only (GPT Image on OpenAI; forwarded on Azure) |
| `output_compression` | integer | `0`-`100`; only with `output_format: :jpeg` or `:webp`, dropped with a warning for PNG (GPT Image on OpenAI and Azure only) |
| `input_fidelity` | atom/string | `:high` or `:low`; edits only, dropped on `gpt-image-1-mini`, ignored by `gpt-image-2` (GPT Image on OpenAI and Azure only) |
| `seed` | integer | Random seed for reproducibility (provider-dependent; **not supported by OpenAI or Azure**) |
| `negative_prompt` | string | What to avoid in the image (provider-dependent; **not supported by OpenAI or Azure**) |
| `source_image` | binary | Source image bytes for editing or reference generation (OpenAI and Azure image models only) |
| `source_image_media_type` | string | MIME type for `source_image` (default: `"image/png"`; OpenAI and Azure image models only) |
| `mask` | binary | Optional mask image bytes for inpainting/editing (OpenAI and Azure image models only) |
| `mask_media_type` | string | MIME type for `mask` (default: `"image/png"`; OpenAI and Azure image models only) |

## Discovering Available Models

```elixir
# List all models that support image generation
ReqLLM.Images.supported_models()
# => ["openai:gpt-image-1", "openai:dall-e-3", "google:gemini-2.5-flash-image", ...]

# Validate a specific model
{:ok, model} = ReqLLM.Images.validate_model("openai:gpt-image-1")
```

---

## OpenAI

OpenAI offers several image generation models through the Images API.

### Supported Models

The GPT Image family provides superior instruction following, text rendering, detailed editing, and real-world knowledge. We recommend `gpt-image-2` for the latest image generation model, or `gpt-image-1-mini` for cost-effective generation when image quality isn't the priority.

| Model | Notes |
|-------|-------|
| `gpt-image-2` | Latest GPT Image model |
| `gpt-image-1.5` | State-of-the-art, best overall quality |
| `gpt-image-1` | Deprecated; scheduled for removal on October 23, 2026 |
| `gpt-image-1-mini` | Cost-effective option for simpler use cases |
| `dall-e-3` | Removed from the OpenAI API on May 12, 2026; use GPT Image models instead |
| `dall-e-2` | Removed from the OpenAI API on May 12, 2026; use GPT Image models instead |

### Sizes and Aspect Ratios

The Images API accepts a fixed set of sizes rather than a free-form aspect ratio, so `aspect_ratio` is resolved to the closest size the model offers. An explicit `size` always wins.

| Requested ratio | GPT Image | DALL-E 3 | DALL-E 2 |
|---|---|---|---|
| square (`"1:1"`) | `1024x1024` | `1024x1024` | `1024x1024` |
| landscape (`"16:9"`, `"3:2"`, …) | `1536x1024` | `1792x1024` | `1024x1024` |
| portrait (`"9:16"`, `"2:3"`, …) | `1024x1536` | `1024x1792` | `1024x1024` |

Because only three shapes exist, the result is an approximation: `"16:9"` yields a 3:2 image on GPT Image. Pass `size` directly when you need exact dimensions.

`seed` and `negative_prompt` have no equivalent in the Images API and are rejected with `ReqLLM.Error.Invalid.Parameter` before the request is sent, rather than being forwarded and returning an `unknown_parameter` error from the provider. To steer away from unwanted content, describe the exclusion in the prompt itself.

### Image Editing

Pass `source_image` to use OpenAI's image edits endpoint. This supports reference-image generation and masked edits while returning the same canonical `ReqLLM.Response` shape as prompt-only generation.

```elixir
source_image = File.read!("source.png")

{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "Create a polished product hero image using this as reference",
  source_image: source_image,
  source_image_media_type: "image/png",
  output_format: :png
)

image_data = ReqLLM.Response.image_data(response)
```

GPT Image quality tiers are accepted as atoms or strings:

```elixir
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "Edit this image as a watercolor illustration",
  source_image: File.read!("source.png"),
  quality: :medium
)
```

For inpainting-style edits, include `mask`:

```elixir
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "Replace the background with a snowy mountain scene",
  source_image: File.read!("source.png"),
  mask: File.read!("mask.png")
)
```

### Current Limitations

The following OpenAI features are not yet exposed by ReqLLM:

- **Responses API image generation tool** (generates images inline during chat)
- **Streaming image generation/editing** via the OpenAI Images API

### Prompt Format

OpenAI's Images API accepts a **single text prompt** plus optional image edit inputs. It does not support multi-turn conversations through `ReqLLM.generate_image/3`. Be descriptive in your prompt to get the best results.

```elixir
# Good: Descriptive prompt
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1",
  "A cozy coffee shop interior with warm lighting, exposed brick walls,
   vintage furniture, and steam rising from ceramic cups on wooden tables"
)
```

### Size Options

**GPT Image models** (gpt-image-1.5, gpt-image-1, gpt-image-1-mini):

- `"1024x1024"` (square, fastest)
- `"1536x1024"` (landscape)
- `"1024x1536"` (portrait)
- `"auto"` (default)

gpt-image-2 and later also accept any `"WIDTHxHEIGHT"` with both sides divisible by 16 and a ratio between 1:3 and 3:1, e.g. `"1536x864"`. Pass such a size explicitly; `aspect_ratio` still snaps to the three standard sizes above.

**dall-e-3:**

- `"1024x1024"`
- `"1792x1024"` (landscape)
- `"1024x1792"` (portrait)

**dall-e-2:**

- `"256x256"`, `"512x512"`, `"1024x1024"`

### GPT Image Options

Every parameter the Images API documents for the GPT Image family is a top-level option:

```elixir
# A cutout for a slide: transparent PNG at the cheapest tier
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "A golden retriever puppy sticker, isolated on a transparent background",
  background: :transparent,
  quality: :low
)

# A compressed JPEG with relaxed moderation
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "A watercolor lighthouse",
  output_format: :jpeg,
  output_compression: 70,
  moderation: :low
)

# An edit that stays close to the source
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1.5",
  "Turn this photo into a line drawing",
  source_image: File.read!("photo.png"),
  input_fidelity: :high
)
```

| Option | Values | Description |
|--------|--------|-------------|
| `quality` | `:auto`, `:low`, `:medium`, `:high`, `:xhigh`, `:max` | Generation tier; `:xhigh` and `:max` are gpt-image-2.5 only and rejected by the API elsewhere; `:standard`/`:hd` are translated to `:medium`/`:high` with a warning |
| `size` | `"1024x1024"`, `"1536x1024"`, `"1024x1536"`, `"auto"` | See [Size Options](#size-options) |
| `background` | `:auto`, `:transparent`, `:opaque` | `:transparent` requires `output_format: :png` (default) or `:webp`; JPEG is rejected before the request is sent |
| `moderation` | `:auto`, `:low` | Generations only; dropped with a warning on edits |
| `output_compression` | `0`-`100` | Only with `output_format: :jpeg` or `:webp`; dropped with a warning for PNG |
| `input_fidelity` | `:high`, `:low` | Edits only (needs `source_image`); dropped with a warning on generations and on `gpt-image-1-mini`; `gpt-image-2` accepts it but ignores it |

Every drop is reported through `on_unsupported` (`:warn` by default, `:error` to fail instead). A value the model itself rejects comes back as `ReqLLM.Error.API.Request` carrying the HTTP status and the provider's message in `response_body`, never silently.

The response echoes what was produced under `response.provider_meta["openai"]` (`"background"`, `"output_format"`, `"quality"`, `"size"`), and each image part's `media_type` follows the echoed `output_format`.

### DALL-E Options

```elixir
{:ok, response} = ReqLLM.generate_image(
  "openai:dall-e-3",
  "A mountain landscape at sunset",
  size: "1792x1024",
  quality: :hd,
  style: :vivid,
  response_format: :url
)
```

**dall-e-3 specific options:**

| Option | Values | Description |
|--------|--------|-------------|
| `quality` | `:standard`, `:hd` | Image detail level |
| `style` | `:vivid`, `:natural` | Artistic vs realistic style |

### Revised Prompts

DALL-E 3 may automatically enhance your prompt for better results. The revised prompt is available in the response metadata:

```elixir
{:ok, response} = ReqLLM.generate_image("openai:dall-e-3", "A cat")

[image_part] = ReqLLM.Response.images(response)
revised = image_part.metadata[:revised_prompt]
# => "A fluffy orange tabby cat sitting gracefully on a windowsill..."
```

---

## Azure

Azure hosts the OpenAI GPT Image family (`gpt-image-1`, `gpt-image-1.5`, `gpt-image-2`) behind Azure OpenAI resources. The wire format matches OpenAI's Images API, so the same options apply, but Azure requires a `base_url` and a `deployment`:

```elixir
{:ok, response} = ReqLLM.generate_image(
  "azure:gpt-image-1",
  "A watercolor painting of a lighthouse",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-image-deployment",
  size: "1024x1024"
)
```

Image editing works the same way as OpenAI's (multipart upload with `source_image` and optional `mask`):

```elixir
{:ok, response} = ReqLLM.generate_image(
  "azure:gpt-image-1",
  "Make the sky stormy",
  base_url: "https://my-resource.openai.azure.com/openai",
  deployment: "my-image-deployment",
  source_image: File.read!("lighthouse.png")
)
```

Notes:

- Supported endpoint formats: traditional Azure OpenAI (`https://<resource>.openai.azure.com/openai`, deployment in the URL path) and the v1 GA API (`.../openai/v1`, deployment sent as `model` in the body). Azure AI Foundry endpoints (`.services.ai.azure.com`) are not supported for image generation.
- All three gpt-image models work on either endpoint format. A `DeploymentNotFound` (HTTP 404) means the `deployment` you passed does not exist on the resource — deployment names are chosen when the deployment is created and often differ from the model id, so pass `deployment:` explicitly rather than relying on the model-id default.
- The default `api_version` (`2025-04-01-preview`) satisfies gpt-image models; override via `provider_options: [api_version: ...]` if needed.
- GPT Image models always return base64 image data (`:binary`); URL responses are not available.
- Option handling matches OpenAI's exactly, including `aspect_ratio` resolving to the nearest supported size and `seed`/`negative_prompt` being rejected — see [Sizes and Aspect Ratios](#sizes-and-aspect-ratios).
- Azure supports `output_format: :png` and `output_format: :jpeg`. It does not support `:webp`, and ReqLLM rejects that value before it sends the request.
- The [GPT Image options](#gpt-image-options) apply unchanged: `background: :transparent` (with the default PNG output), `output_compression` with `output_format: :jpeg`, `input_fidelity` on edits, and the `quality` tiers. `moderation` is forwarded as-is; Azure does not document it, so a deployment that rejects it returns an API error.
- DALL-E models are retired on Azure — use gpt-image models.
- Only `gpt-image-*` model ids are accepted. Chat models (e.g. `azure:gpt-4o`) are rejected locally with a `ReqLLM.Error.Invalid.Parameter` before any HTTP call, rather than failing at the API.
- The `deployment` name is free-form and affects only the URL/body identifier. Option handling is keyed off the catalog model id, so a deployment named after a different model does not change which options are sent.
- Responses carry provider metadata under `response.provider_meta["azure"]`, and `response.usage.image_usage` is populated the same way as for OpenAI.

See the [Azure guide](azure.md) for authentication and deployment configuration.

---

## Google (Gemini)

Google's Gemini models support both text-to-image generation and image editing through multi-turn conversations.

### Supported Models

| Model | Alias | Notes |
|-------|-------|-------|
| `gemini-2.5-flash-image` | Nano Banana | Fast generation, good for quick iterations and standard tasks |
| `gemini-3-pro-image-preview` | Nano Banana Pro | State-of-the-art quality, advanced text rendering, professional assets |
| `imagen-4.0-generate-001` | Imagen 4 | High-quality photorealistic images |
| `imagen-4.0-fast-generate-001` | Imagen 4 Fast | Faster generation with good quality |

### Model Selection

**Choose Gemini 2.5 Flash** for:

- Quick prototyping and iteration
- Straightforward text-to-image tasks
- Speed-sensitive applications

**Choose Gemini 3 Pro Preview** for:

- Professional-grade asset production
- Complex multi-turn editing workflows
- Text-heavy designs (logos, menus, infographics, diagrams)
- Character consistency across multiple images
- High-resolution output (1K, 2K, 4K)
- Tasks requiring advanced reasoning

**Choose Imagen** for:

- High-quality photorealistic images
- When you don't need multi-turn editing capabilities

### Basic Generation

Note: `gemini-2.5-flash-image` and `gemini-3-pro-image-preview` reject `n`; specify the image count in the prompt.

```elixir
{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  "A futuristic cityscape with flying cars and neon lights",
  aspect_ratio: "16:9"
)
```

### Generating Multiple Images

**Important:** Google's documentation states that "the model won't always follow the exact number of image outputs that the user explicitly asks for." Multi-image generation is inherently unreliable, and prompt phrasing significantly affects success rates.

**Effective prompt patterns** (higher success rate):

```elixir
# Numbered list format - works well
{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  "Generate multiple images: 1) A white cat 2) A black cat"
)

# Sequential instructions - works well
{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  "Generate the first image of a sunrise, then generate a second image of a sunset"
)

# Labeled scenes - works well
{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  "Generate multiple scenes: Scene A shows a forest, Scene B shows a desert"
)

images = ReqLLM.Response.images(response)
# May return 1 or 2 images depending on model behavior
```

**Less effective prompt patterns** (often returns only 1 image):

```elixir
# Simple count requests - often fails
"Generate two images of cats"
"Create 2 pictures of a banana"

# Even with emphasis - often fails
"Create two DISTINCT and SEPARATE images"
```

The model may respond with text like "here are two images" but only deliver one. For reliable multi-image workflows, consider making multiple API calls or using the numbered list format above.

### Aspect Ratios

Google supports flexible aspect ratios:

- `"1:1"` (square)
- `"3:4"`, `"4:3"`
- `"4:5"`, `"5:4"`
- `"9:16"`, `"16:9"`
- `"2:3"`, `"3:2"`
- `"21:9"` (ultrawide)

### Image Editing with Context

Unlike OpenAI, Google Gemini supports **image editing** by including an existing image in the conversation context. This enables powerful workflows like style transfer, object addition/removal, and iterative refinement.

```elixir
alias ReqLLM.{Context, Message}
alias ReqLLM.Message.ContentPart

# Load an existing image
{:ok, original_image} = File.read("photo.jpg")

# Create a context with the image and editing instructions
context = Context.new([
  %Message{
    role: :user,
    content: [
      ContentPart.image(original_image, "image/jpeg"),
      ContentPart.text("Add a rainbow in the sky above the mountains")
    ]
  }
])

# Generate the edited image
{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  context,  # Pass the full context instead of a string
  aspect_ratio: "16:9"
)

edited_image = ReqLLM.Response.image_data(response)
File.write!("photo_with_rainbow.png", edited_image)
```

### Multi-Turn Image Refinement

You can iteratively refine images through conversation:

```elixir
alias ReqLLM.{Context, Message, Response}
alias ReqLLM.Message.ContentPart

# Initial generation
{:ok, response1} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  "A medieval castle on a hilltop"
)

first_image = Response.image_data(response1)

# Refine: add details
context = Context.new([
  %Message{
    role: :user,
    content: [
      ContentPart.image(first_image, "image/png"),
      ContentPart.text("Add a dramatic sunset behind the castle with orange and purple clouds")
    ]
  }
])

{:ok, response2} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  context
)

# Further refinement
second_image = Response.image_data(response2)

context2 = Context.new([
  %Message{
    role: :user,
    content: [
      ContentPart.image(second_image, "image/png"),
      ContentPart.text("Add a dragon flying near one of the castle towers")
    ]
  }
])

{:ok, final_response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  context2
)
```

### Style Transfer

Apply artistic styles to existing images:

```elixir
{:ok, photo} = File.read("portrait.jpg")

context = Context.new([
  %Message{
    role: :user,
    content: [
      ContentPart.image(photo, "image/jpeg"),
      ContentPart.text("Transform this photo into a watercolor painting style")
    ]
  }
])

{:ok, response} = ReqLLM.generate_image(
  "google:gemini-2.5-flash-image",
  context
)
```

### Prompting Tips for Google

Google recommends describing scenes rather than listing keywords:

```elixir
# Less effective
"cat, sitting, window, sunlight, cozy"

# More effective
"A content tabby cat lounging on a sunny windowsill,
 warm afternoon light streaming through sheer curtains"
```

---

## Usage & Cost Tracking

Image generation responses include detailed usage and cost information:

### Basic Usage

```elixir
{:ok, response} = ReqLLM.generate_image("openai:gpt-image-1", prompt)

response.usage
#=> %{
#     image_usage: %{
#       generated: %{count: 1, size_class: "1024x1024"}
#     },
#     cost: %{
#       images: 0.04,
#       tokens: 0.0,
#       tools: 0.0,
#       total: 0.04
#     },
#     input_cost: 0.0,
#     output_cost: 0.04,
#     total_cost: 0.04
#   }
```

### Size Classes

Image costs vary by size. The `size_class` field indicates the resolution tier used for billing:

| Provider | Size Classes |
|----------|-------------|
| OpenAI | `"1024x1024"`, `"1536x1024"`, `"1024x1536"`, `"auto"` |
| Google | Based on aspect ratio (e.g., `"1:1"`, `"16:9"`) |

### Multiple Images

When generating multiple images, the `count` reflects the total:

```elixir
{:ok, response} = ReqLLM.generate_image("openai:dall-e-2", prompt, n: 3)

response.usage.image_usage.generated
#=> %{count: 3, size_class: "1024x1024"}
```

---

## Error Handling

```elixir
case ReqLLM.generate_image("openai:gpt-image-1", prompt) do
  {:ok, response} ->
    image_data = ReqLLM.Response.image_data(response)
    File.write!("output.png", image_data)

  {:error, %ReqLLM.Error.API.Request{status: 400, response_body: body}} ->
    IO.puts("Bad request: #{inspect(body)}")

  {:error, %ReqLLM.Error.Invalid.Parameter{} = error} ->
    IO.puts("Invalid parameter: #{Exception.message(error)}")

  {:error, error} ->
    IO.puts("Error: #{inspect(error)}")
end
```

## Testing with Fixtures

Use fixtures to test image generation without making API calls:

```elixir
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1",
  "A test prompt",
  fixture: "image_basic"
)
```

See the [Fixture Testing](fixture-testing.md) guide for details.
