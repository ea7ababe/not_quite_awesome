defmodule HTTP do
  defmodule RequestError do
	defstruct [:code, :message, :url]
	@type t :: %RequestError{code: integer, message: charlist, url: charlist}
  end

  def get(url) do
	headers = [{'user-agent', 'curl/7.63.0'}]
	rq = {url, headers}
	case :httpc.request(:get, rq, [], []) do
	  {:ok, {status, _headers, body}} ->
		case status_code(status) do
		  200 ->
			body
		  code ->
			throw %RequestError{code: code, url: url, message: body}
		end
	  {:error, _reason} ->
		throw %RequestError{url: url, message: "connection error"}
	end
  end

  defp status_code({_, code, _}), do: code
end
