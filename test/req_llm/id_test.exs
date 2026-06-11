defmodule ReqLLM.IDTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ReqLLM.ID

  describe "uuid7/0" do
    test "returns a lowercase RFC 9562 UUIDv7 string" do
      uuid = ID.uuid7()

      assert uuid =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "sets all RFC 9562 UUIDv7 fields in the correct bit positions" do
      before_ms = System.system_time(:millisecond)
      uuid = ID.uuid7()
      after_ms = System.system_time(:millisecond)

      assert %{
               unix_ts_ms: timestamp_ms,
               version: 7,
               variant: 0b10,
               rand_a: rand_a,
               rand_b: rand_b
             } = decode_uuid7(uuid)

      assert timestamp_ms >= before_ms
      assert timestamp_ms <= after_ms
      assert rand_a in 0..0xFFF
      assert rand_b in 0..0x3FFFFFFFFFFFFFFF
    end

    test "matches the RFC 9562 UUIDv7 example test vector" do
      timestamp_ms = 0x017F22E279B0
      rand_a = 0xCC3
      rand_b = 0b01 <<< 60 ||| 0x8C4DC0C0C07398F
      random_bytes = <<rand_a::12, rand_b::62, 0::6>>

      assert ID.uuid7(timestamp_ms, random_bytes) == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
    end

    test "handles the minimum and maximum representable UUIDv7 field values" do
      assert ID.uuid7(0, <<0::80>>) == "00000000-0000-7000-8000-000000000000"

      assert ID.uuid7(0xFFFFFFFFFFFF, :binary.copy(<<0xFF>>, 10)) ==
               "ffffffff-ffff-7fff-bfff-ffffffffffff"
    end

    test "orders lexicographically by timestamp when random bits are identical" do
      random_bytes = <<0::80>>

      assert ID.uuid7(1, random_bytes) < ID.uuid7(2, random_bytes)
    end

    test "uses the high 74 random bits and ignores the 6 excess random bits" do
      timestamp_ms = 0x017F22E279B0
      rand_a = 0x123
      rand_b = 0x2345_6789_ABCD_EF0

      uuid_with_zero_padding = ID.uuid7(timestamp_ms, <<rand_a::12, rand_b::62, 0::6>>)
      uuid_with_one_padding = ID.uuid7(timestamp_ms, <<rand_a::12, rand_b::62, 0b111111::6>>)

      assert uuid_with_zero_padding == uuid_with_one_padding
      assert %{rand_a: ^rand_a, rand_b: ^rand_b} = decode_uuid7(uuid_with_zero_padding)
    end

    test "rejects timestamps that do not fit the 48-bit UUIDv7 timestamp field" do
      uuid7 = Function.capture(ID, :uuid7, 2)

      assert_raise FunctionClauseError, fn ->
        ID.uuid7(0x1_0000_0000_0000, <<0::80>>)
      end

      assert_raise FunctionClauseError, fn ->
        ID.uuid7(-1, <<0::80>>)
      end

      assert_raise FunctionClauseError, fn ->
        uuid7.("0", <<0::80>>)
      end
    end

    test "rejects random inputs that are not exactly 80 bits" do
      uuid7 = Function.capture(ID, :uuid7, 2)

      assert_raise FunctionClauseError, fn ->
        ID.uuid7(0, <<0::72>>)
      end

      assert_raise FunctionClauseError, fn ->
        ID.uuid7(0, <<0::88>>)
      end

      assert_raise FunctionClauseError, fn ->
        uuid7.(0, :not_binary)
      end
    end

    test "generates unique values across repeated calls" do
      ids = for _ <- 1..1_000, do: ID.uuid7()

      assert ids |> Enum.uniq() |> length() == length(ids)
    end
  end

  defp decode_uuid7(uuid) do
    {:ok, bytes} =
      uuid
      |> String.replace("-", "")
      |> Base.decode16(case: :mixed)

    <<unix_ts_ms::48, version::4, rand_a::12, variant::2, rand_b::62>> = bytes

    %{
      unix_ts_ms: unix_ts_ms,
      version: version,
      rand_a: rand_a,
      variant: variant,
      rand_b: rand_b
    }
  end
end
