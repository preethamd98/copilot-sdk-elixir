defmodule CopilotSdk.JsonRpc.FramingTest do
  use ExUnit.Case, async: true

  alias CopilotSdk.JsonRpc.Framing

  describe "encode/1" do
    test "encodes a map with Content-Length header" do
      msg = %{"jsonrpc" => "2.0", "method" => "ping", "id" => "1"}
      assert {:ok, frame} = Framing.encode(msg)
      assert frame =~ "Content-Length:"
      assert frame =~ "\r\n\r\n"
      assert frame =~ "ping"
    end

    test "Content-Length matches JSON byte size" do
      msg = %{"jsonrpc" => "2.0", "method" => "test", "params" => %{"key" => "value"}}
      {:ok, frame} = Framing.encode(msg)
      [header, body] = String.split(frame, "\r\n\r\n", parts: 2)
      [_, length_str] = String.split(header, ": ")
      assert String.to_integer(length_str) == byte_size(body)
    end

    test "handles UTF-8 content correctly" do
      msg = %{"data" => "héllo wörld 🌍"}
      {:ok, frame} = Framing.encode(msg)
      [header, body] = String.split(frame, "\r\n\r\n", parts: 2)
      [_, length_str] = String.split(header, ": ")
      assert String.to_integer(length_str) == byte_size(body)
    end
  end

  describe "parse/1" do
    test "parses a single complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => "1", "result" => "ok"})
      buffer = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
      {messages, rest} = Framing.parse(buffer)
      assert length(messages) == 1
      assert hd(messages)["result"] == "ok"
      assert rest == ""
    end

    test "parses multiple messages in one buffer" do
      msg1 = Jason.encode!(%{"id" => "1", "result" => "a"})
      msg2 = Jason.encode!(%{"id" => "2", "result" => "b"})

      buffer =
        "Content-Length: #{byte_size(msg1)}\r\n\r\n#{msg1}" <>
          "Content-Length: #{byte_size(msg2)}\r\n\r\n#{msg2}"

      {messages, rest} = Framing.parse(buffer)
      assert length(messages) == 2
      assert Enum.at(messages, 0)["result"] == "a"
      assert Enum.at(messages, 1)["result"] == "b"
      assert rest == ""
    end

    test "returns incomplete buffer when message is partial" do
      json = Jason.encode!(%{"id" => "1", "result" => "ok"})
      partial = "Content-Length: #{byte_size(json)}\r\n\r\n#{String.slice(json, 0, 5)}"
      {messages, rest} = Framing.parse(partial)
      assert messages == []
      assert rest == partial
    end

    test "returns incomplete when header is partial" do
      {messages, rest} = Framing.parse("Content-Le")
      assert messages == []
      assert rest == "Content-Le"
    end

    test "handles empty buffer" do
      {messages, rest} = Framing.parse("")
      assert messages == []
      assert rest == ""
    end

    test "handles message followed by partial message" do
      msg1 = Jason.encode!(%{"id" => "1", "result" => "complete"})
      msg2_json = Jason.encode!(%{"id" => "2", "result" => "incomplete"})
      partial2 = String.slice(msg2_json, 0, 5)

      buffer =
        "Content-Length: #{byte_size(msg1)}\r\n\r\n#{msg1}" <>
          "Content-Length: #{byte_size(msg2_json)}\r\n\r\n#{partial2}"

      {messages, rest} = Framing.parse(buffer)
      assert length(messages) == 1
      assert hd(messages)["result"] == "complete"
      assert rest =~ "Content-Length"
    end
  end

  describe "extract_one/1" do
    test "extracts a single message" do
      json = Jason.encode!(%{"method" => "test"})
      buffer = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}remaining"
      assert {:ok, msg, rest} = Framing.extract_one(buffer)
      assert msg["method"] == "test"
      assert rest == "remaining"
    end

    test "returns :incomplete for partial data" do
      assert :incomplete = Framing.extract_one("Content-Length: 100\r\n\r\nshort")
    end
  end

  describe "round-trip" do
    test "encode then parse produces original message" do
      original = %{"jsonrpc" => "2.0", "id" => "42", "method" => "ping", "params" => %{}}
      {:ok, frame} = Framing.encode(original)
      {[decoded], ""} = Framing.parse(frame)
      assert decoded == original
    end
  end
end
