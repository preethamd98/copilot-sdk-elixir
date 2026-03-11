defmodule CopilotSdk.JsonRpc.Framing do
  @moduledoc """
  LSP-style Content-Length framing for JSON-RPC 2.0 messages.

  Parses and encodes messages with `Content-Length: N\\r\\n\\r\\n{json}` framing.
  """

  @doc """
  Encode a JSON-RPC message map into a Content-Length framed binary.
  """
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(message) when is_map(message) do
    case Jason.encode(message) do
      {:ok, json} ->
        frame = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
        {:ok, frame}

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end

  @doc """
  Parse a buffer that may contain one or more Content-Length framed messages.

  Returns `{messages, remaining_buffer}` where `messages` is a list of
  decoded JSON maps and `remaining_buffer` is any leftover bytes.
  """
  @spec parse(binary()) :: {[map()], binary()}
  def parse(buffer) when is_binary(buffer) do
    parse_loop(buffer, [])
  end

  defp parse_loop(buffer, acc) do
    case extract_one(buffer) do
      {:ok, message, rest} ->
        parse_loop(rest, [message | acc])

      :incomplete ->
        {Enum.reverse(acc), buffer}
    end
  end

  @doc """
  Extract a single Content-Length framed message from the buffer.

  Returns `{:ok, message, rest}` or `:incomplete`.
  """
  @spec extract_one(binary()) :: {:ok, map(), binary()} | :incomplete
  def extract_one(buffer) do
    case parse_header(buffer) do
      {:ok, content_length, body_start} ->
        if byte_size(body_start) >= content_length do
          <<json_bytes::binary-size(content_length), rest::binary>> = body_start

          case Jason.decode(json_bytes) do
            {:ok, message} -> {:ok, message, rest}
            {:error, _} -> :incomplete
          end
        else
          :incomplete
        end

      :incomplete ->
        :incomplete
    end
  end

  defp parse_header(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {pos, 4} ->
        header_part = binary_part(buffer, 0, pos)
        body_start = binary_part(buffer, pos + 4, byte_size(buffer) - pos - 4)

        case parse_content_length(header_part) do
          {:ok, length} -> {:ok, length, body_start}
          :error -> :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp parse_content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        ["Content-Length", value] ->
          case Integer.parse(String.trim(value)) do
            {n, ""} when n >= 0 -> {:ok, n}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end
end
