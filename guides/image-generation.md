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
| `aspect_ratio` | string | Aspect ratio, e.g., `"16:9"` or `"1:1"` |
| `output_format` | atom | Image format: `:png`, `:jpeg`, or `:webp` |
| `response_format` | atom | Return type: `:binary` (default) or `:url` |
| `quality` | atom/string | Image quality (provider-dependent) |
| `seed` | integer | Random seed for reproducibility (provider-dependent) |
| `negative_prompt` | string | What to avoid in the image (provider-dependent) |

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

The GPT Image family provides superior instruction following, text rendering, detailed editing, and real-world knowledge. We recommend `gpt-image-1.5` for the best quality, or `gpt-image-1-mini` for cost-effective generation when image quality isn't the priority.

| Model | Notes |
|-------|-------|
| `gpt-image-1.5` | State-of-the-art, best overall quality |
| `gpt-image-1` | High fidelity with transparency support |
| `gpt-image-1-mini` | Cost-effective option for simpler use cases |
| `dall-e-3` | Higher quality than DALL-E 2, larger resolutions (deprecated May 2026) |
| `dall-e-2` | Lower cost, supports inpainting/variations (deprecated May 2026) |

### Current Limitations

ReqLLM currently supports **image generation only** via the Images API. The following OpenAI features are not yet supported:

- **Image editing** (editing with masks via the Images API)
- **Image variations** (DALL-E 2 only)
- **Responses API image generation tool** (generates images inline during chat)

### Prompt Format

OpenAI's image generation accepts only a **single text prompt** - it does not support multi-turn conversations or image editing via context. Be descriptive in your prompt to get the best results.

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

**dall-e-3:**

- `"1024x1024"`
- `"1792x1024"` (landscape)
- `"1024x1792"` (portrait)

**dall-e-2:**

- `"256x256"`, `"512x512"`, `"1024x1024"`

### OpenAI-Specific Options

```elixir
# gpt-image-1 with transparency
{:ok, response} = ReqLLM.generate_image(
  "openai:gpt-image-1",
  "A golden retriever puppy, isolated on transparent background",
  output_format: :png,
  provider_options: [background: "transparent"]
)

# dall-e-3 with style
{:ok, response} = ReqLLM.generate_image(
  "openai:dall-e-3",
  "A mountain landscape at sunset",
  size: "1792x1024",
  quality: :hd,
  style: :vivid  # or :natural for more realistic
)
```

**GPT Image specific options** (via `provider_options`):

| Option | Values | Description |
|--------|--------|-------------|
| `background` | `"transparent"`, `"opaque"`, `"auto"` | Background transparency (use PNG/WebP format) |
| `moderation` | `"auto"`, `"low"` | Content moderation strictness |

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
