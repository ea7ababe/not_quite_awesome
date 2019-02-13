defmodule NotQuiteAwesome.MixProject do
  use Mix.Project

  def project do
    [
      app: :nqa,
      version: "0.1.0",
      elixir: "~> 1.7",
      escript: [main_module: NotQuiteAwesome.Main],
      default_task: "escript.build",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:earmark, "~> 1.3"}
    ]
  end
end
