# Billing regression evidence

`anthropic_haiku_5_5_mixed_ttl.json` contains small response extracts from two
live calls made on 2026-10-09. One call was buffered and one was streamed.
The large request prefixes remain in the original local run directory.

Both calls originally failed the billing check with LLMDB 2026.10.1. The SDK
reported USD 0.008261. The independent calculation was USD 0.010739. The JSON
keeps those failed states, original charges, capture times, and complete source
hashes. It also keeps the provider response or the exact encoded stream chunks,
the frozen rate book, and the independent calculation.

These extracts are regression evidence. They are not promoted live baselines.
The original manifests, observations, transcripts, and worksheets remain
unchanged. The tests replay the saved provider facts against the released
LLMDB 2026.10.2 catalog. The separate 100,000 and 100,001 prompt tests generate
usage variants; they are not live observations. None of these tests makes a
provider request.
