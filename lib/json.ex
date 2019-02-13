defmodule JSON do
  use Bitwise

  @type json :: atom | binary | list | map | number

  @spec decode(binary, Keyword.t) ::
    { :ok, json } |
    { :error, atom }
  def decode(bin, opts \\ []), do: wrap(&decode!/2, bin, opts)

  @spec decode!(binary, Keyword.t) :: json | no_return
  def decode!(bin, _opts \\ []) when is_binary(bin) do
    { rest, value } = do_decode(strip_ws(bin))
    "" = strip_ws(rest); value
  rescue _ -> raise ArgumentError
  end

  defp do_decode(<< "\"",    rem :: binary >>), do: decode_string(rem, "")
  defp do_decode(<< "{",     rem :: binary >>), do: decode_object(strip_ws(rem), [])
  defp do_decode(<< "[",     rem :: binary >>), do: decode_array(strip_ws(rem), [])
  defp do_decode(<< "true",  rem :: binary >>), do: { strip_ws(rem), true }
  defp do_decode(<< "false", rem :: binary >>), do: { strip_ws(rem), false }
  defp do_decode(<< "null",  rem :: binary >>), do: { strip_ws(rem), nil }
  defp do_decode(<< val, _rest :: binary >> = bin) when val in '0123456789-',
    do: decode_number(bin)

  defp decode_array(<< "]", rest :: binary >>, []), do: { strip_ws(rest), [] }
  defp decode_array(bin, acc) do
    { rest, value } = do_decode(bin)
    enforce_array_terminator(rest, [ value | acc ])
  end

  defp enforce_array_terminator(<< ",", rest :: binary >>, acc),
    do: decode_array(strip_ws(rest), acc)
  defp enforce_array_terminator(<< "]", rest :: binary >>, acc),
    do: { strip_ws(rest), :lists.reverse(acc) }

  defp decode_number(bin) do
    count = detect_number(bin, 0, 0)
    << number :: binary-size(count), rest :: binary >> = bin
    { strip_ws(rest), parse_numeric(Integer.parse(number), number) }
  end

  defp detect_number(<< "0", rest :: binary >>, acc, 0),
    do: enforce_zero(rest, acc + 1)
  defp detect_number(<< ".", rest :: binary >>, acc, _zero),
    do: detect_number(rest, acc + 1, 1)
  defp detect_number(<< val, rest :: binary >>, acc, _zero) when val in '123456789.eE',
    do: detect_number(rest, acc + 1, 1)
  defp detect_number(<< val, rest :: binary >>, acc, zero) when val in '0-+',
    do: detect_number(rest, acc + 1, zero)
  defp detect_number(_bin, acc, _zero), do: acc

  defp enforce_zero(<< val, rest :: binary >>, acc) when val in '.eE',
    do: detect_number(rest, acc + 1, 1)
  defp enforce_zero(<< val, _rest :: binary >>, acc) when not(val in '0123456789+-'),
    do: acc
  defp enforce_zero(<< >>, acc), do: acc

  defp parse_numeric({ num, "" }, _val), do: num
  defp parse_numeric(_error, val) do
    { num, "" } = Float.parse(val)
      num
  end

  defp decode_object(<< "\"", bin :: binary >>, acc) do
    { << ":", rem1 :: binary >>, key } = decode_string(bin, "")
    { rem2, val } = do_decode(strip_ws(rem1))
    enforce_object_terminator(rem2, [ { key, val } | acc ])
  end
  defp decode_object(<< "}", rest :: binary >>, []), do: { strip_ws(rest), %{} }

  defp enforce_object_terminator(<< ",", rest :: binary >>, acc),
    do: decode_object(strip_ws(rest), acc)
  defp enforce_object_terminator(<< "}", rest :: binary >>, acc),
    do: { strip_ws(rest), :maps.from_list(:lists.reverse(acc)) }

  defp decode_string(<< "\\", rest :: binary >>, acc) do
    { remainder, value } = string_escape(rest)
    decode_string(remainder, [ acc, value ])
  end
  defp decode_string(<< "\"", rest :: binary >>, acc),
    do: { strip_ws(rest), :erlang.iolist_to_binary(acc) }
  defp decode_string(bin, acc) do
    valid_count = detect_string(bin, 0, &shift_point/3)
    << value :: binary-size(valid_count), rest :: binary >> = bin
    decode_string(rest, [ acc, value ])
  end

  defp shift_point(<< val :: utf8, rest :: binary >>, acc, ca),
    do: detect_string(rest, acc + cp_value(val), ca)

  for { key, replace } <- List.zip(['"\\ntr/fb', '"\\\n\t\r/\f\b']) do
    defp string_escape(<< unquote(key), rest :: binary >>),
      do: { rest, unquote(replace) }
  end
  defp string_escape(<< ?u, l1, l2, l3, l4, "\\u", r1, r2, r3, r4, rest :: binary >>)
  when l1 in 'dD' and r1 in 'dD' and l2 in '89abAB' and r2 in 'cdefCDEF' do
    c1 = :erlang.list_to_integer([l1, l2, l3, l4], 16) &&& 0x03FF
    c2 = :erlang.list_to_integer([r1, r2, r3, r4], 16) &&& 0x03FF
    { rest, << (0x10000 + (c1 <<< 10) + c2) :: utf8 >> }
  end
  defp string_escape(<< ?u, seq :: binary-4, rest :: binary >>),
    do: { rest, << :erlang.binary_to_integer(seq, 16) :: utf8 >> }

  defp cp_value(val) when val < 0x800, do: 2
  defp cp_value(val) when val < 0x10000, do: 3
  defp cp_value(_val), do: 4

  defp detect_string(<< val, _rest :: binary >>, acc, _ca) when val <= 0x1F,
    do: valid_count!(acc)
  defp detect_string(<< val, _rest :: binary >>, acc, _ca) when val in '"\\',
    do: valid_count!(acc)
  defp detect_string(<< val, rest :: binary >>, acc, ca) when val < 0x80,
    do: detect_string(rest, acc + 1, ca)
  defp detect_string(bin, acc, ca),
    do: ca.(bin, acc, ca)

  defp strip_ws(<< v, rest :: binary >>) when v in '\s\n\t\r', do: strip_ws(rest)
  defp strip_ws(rest), do: rest

  defp valid_count!(0), do: raise ArgumentError
  defp valid_count!(x), do: x

  defp wrap(fun, input, opts) do
    { :ok, fun.(input, opts) }
  rescue _ ->
    { :error, :invalid_input }
  end
end
