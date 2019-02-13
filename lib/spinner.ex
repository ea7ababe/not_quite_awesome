defmodule Spinner do
  @default_format [
    frames: :strokes,
    spinner_color: [],
    text: "Loading…",
    done: "Loaded.",
    interval: 100
  ]

  @themes [
    strokes: ~w[/ - \\ |],
    braille: ~w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏],
    bars: ~w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▇ ▆ ▅ ▄ ▃],
    flip: ~w[_ _ _ - ` ` ' ´ - _ _ _],
    clock: ~w[◴ ◷ ◶ ◵]
  ]

  def render(custom_format \\ @default_format, fun) do
    format = Keyword.merge(@default_format, custom_format)

    config = [
      interval: format[:interval],
      render_frame: fn count -> render_frame(format, count) end,
      render_done: fn -> render_done(format[:done]) end
    ]

    Spinner.AnimationServer.start(config)
    value = fun.()
    Spinner.AnimationServer.stop()
    value
  end

  defp render_frame(format, count) do
    frames = get_frames(format[:frames])
    index = rem(count, length(frames))
    frame = Enum.at(frames, index)

    IO.write([
      ansi_prefix(),
      colorize(frame, format[:spinner_color]),
      " ",
      format[:text]
    ])
  end

  defp render_done(:remove) do
    IO.write(ansi_prefix())
  end

  defp render_done(text) do
    IO.write([
      ansi_prefix(),
      text,
      "\n"
    ])
  end

  defp get_frames(theme) when is_atom(theme), do: Keyword.fetch!(@themes, theme)
  defp get_frames(list) when is_list(list), do: list

  defp ansi_prefix() do
    [IO.ANSI.clear_line, "\r"]
  end

  defp colorize(content, []), do: content
  defp colorize(content, ansi_codes) do
    [ansi_codes, content, IO.ANSI.reset]
  end
end
