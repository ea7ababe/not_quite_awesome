defmodule NotQuiteAwesome.Main do
  @help """
  nqa [-h] [-f] [--dry-run] REPOSITORY SECTION

  NotQuiteAwesome - a parser and sorter of awesome lists on github
                    (https://github.com/sindresorhus/awesome)

  At this time it can only sort one section of a list by the number of
  stars (highest first). The SECTION parameter is a regular expression.

  OPTIONS:
    -h --help
      show this help message
    -f --force
      try to circumvent github API limits
    --dry-run
      download and parse the list, but don't follow and sort the links

  EXAMPLE: nqa drobakowski/awesome-erlang "Text and Numbers"
  will sort all links under the "Text and Numbers" section by stars.

  NOTE:  in order  to  get the  number  of stars  of  a repository  it
  currently relies on  github's JSON API (api.github.com)  which has a
  limit on the  number of requests. You can use  the --dry-run flag in
  order to get the list of repositories, without sorting.
  """

  # Runs the do block while displaying the label with a spinner
  defmacro stage(label, do: op) do
    quote do
      do_stage(unquote(label), fn -> unquote(op) end)
    end
  end

  defp do_stage(label, f) do
    cfg = [frames: :braille, text: label, done: :remove]
    ProgressBar.render_spinner(cfg, f)
  end

  def main(argv) do
    Enum.each([:ssl, :inets], &Application.ensure_all_started/1)

    {repo, section, flags} = getopts(argv)
    section = section_regexp(section)
    readme = fetch_readme(repo)
    repos = find_repo_links(readme, section)

    unless flags[:dry_run] do
      force = flags[:force]
      unless force do
        check_api_limit!(Enum.count(repos))
      end
      scan_mode = if force, do: :ugly, else: :normal
      sort_by_stars(repos, scan_mode) |> format()
    else
      dry_run(repos)
    end
  catch
    :help ->
      IO.write(@help)
    {:abort, msg} ->
      abort(msg)
  end

  defp abort(msg) do
    IO.puts(:stderr, msg)
    System.halt(1)
  end

  defp section_regexp(src) do
    case Regex.compile(src) do
      {:ok, re} ->
        re
      {:error, {msg, _}} ->
        throw {:abort, "Syntax error in SECTION parameter: #{msg}"}
    end
  end

  defp getopts(argv) do
    cfg = [
      strict: [
        dry_run: :boolean,
        force: :boolean,
        help: :boolean
      ],
      aliases: [h: :help, f: :force]
    ]

    {flags, argv, invalid} = OptionParser.parse(argv, cfg)

    unless flags[:help] do
      case {argv, invalid} do
        {[repo, section], []} ->
          {repo, section, flags}
        _ ->
          throw {:abort, "Error: invalid arguments; see --help"}
      end
    else
      throw :help
    end
  end

  def dry_run(repos) do
    report = for {label, repo} <- repos do
        "#{label}: https://github.com/#{repo}\n"
    end

    IO.write :stderr, [
      "Scanning the following repositories:\n",
      "====================================\n",
      report
    ]
  end

  defp format(repos) do
    bad = IO.ANSI.red
    good = IO.ANSI.green
    reset = IO.ANSI.reset

    max_prefix_width = repos
    |> Enum.map(fn({_, _, stars}) -> String.length(to_string(stars)) end)
    |> Enum.max()

    Enum.each repos, fn {label, url, stars} ->
      color = if is_number(stars), do: good, else: bad
      stars = String.pad_leading(to_string(stars), max_prefix_width)
      IO.puts(" #{color}#{stars}#{reset} #{label} (#{url})")
    end

    if Enum.find(repos, fn {_, _, rank} -> rank === :error end) do
      IO.puts :stderr, [
        "\n", bad, "WARNING: ", reset,
        "I were unable to access some repositories ",
        "(probably due to github API rate limit)."
      ]
    end
  end

  defp sort_by_stars(repos, mode) do
    stage "Scanning repositories..." do
      tasks = for {_label, repo} <- repos do
        Task.async(fn -> fetch_repo_stars(repo, mode) end)
      end

      Task.yield_many(tasks, 15000)
      |> Stream.zip(repos)
      |> Stream.map(fn
        {{_, {:ok, stars}}, {label, repo}} ->
          {label, repo, stars}
        {{_, nil}, {label, repo}} ->
          {label, repo, :timeout}
      end)
      |> Enum.sort_by(&elem(&1, 2), &>=/2)
    end
  end

  defp fetch_repo_stars(repo, mode) do
    case mode do
      :normal ->
        HTTP.get('https://api.github.com/repos/#{repo}')
        |> to_string()
        |> JSON.decode!()
        |> Map.get("stargazers_count")
      :ugly ->
        page = HTTP.get('https://github.com/#{repo}') |> to_string()
        case Regex.run(~r<(\d+) users? starred this>, page) do
          [_, stars] ->
            String.to_integer(stars)
          _ ->
            :error
        end
    end
  catch
    %HTTP.RequestError{} ->
      :error
  end

  defp check_api_limit!(minimum) do
    limits = stage "Checking API limits...", do: fetch_api_limits()
    rem = limits.remaining
    if minimum > rem do
      message = [
        "Github API limit exceeded: #{minimum} calls required, got only #{rem}\n",
        "Next limits reset at ", format_timestamp(limits.reset),
        "\nYou can use the --force flag to try and circumvent this."
      ]
      throw {:abort, message}
    end
  end

  defp format_timestamp(t) do
    lt = :calendar.system_time_to_local_time(t, :second)
    {{yy, mm, dd}, {h, m, _s}} = lt
    :io_lib.format('~b-~2..0b-~2..0b ~2..0b:~2..0b', [yy, mm, dd, h, m])
  end

  defp fetch_api_limits() do
    HTTP.get('https://api.github.com/rate_limit')
    |> to_string()
    |> JSON.decode!()
    |> get_in(["resources", "core"])
    |> Enum.reduce(%{}, fn
      {k, v}, acc when k in ~w[remaining reset] and is_number(v) ->
        Map.put(acc, String.to_atom(k), v)
      _, acc ->
        acc
    end)
  end

  defp fetch_readme(repo) do
    readme = stage "Fetching README..." do
      variants = ["README.md", "readme.md", "README.MD"]
      try_readmes(repo, variants)
    end

    if is_nil(readme) do
      throw {:abort, "No README file found"}
    else
      readme
    end
  end

  defp try_readmes(_repo, []), do: nil
  defp try_readmes(repo, [variant | rest]) do
    HTTP.get('https://raw.githubusercontent.com/#{repo}/master/#{variant}')
    |> to_string()
    |> Earmark.parse(%Earmark.Options{smartypants: false})
  catch
    %HTTP.RequestError{} ->
      try_readmes(repo, rest)
  else
    {tree, _} ->
      tree
  end

  alias Earmark.Block.Heading, as: MdH
  alias Earmark.Block.Para, as: MdP
  alias Earmark.Block.List, as: MdL
  alias Earmark.Block.ListItem, as: MdLI
  defp find_repo_links(tree, section) do
    block = Enum.reduce tree, {false, []}, fn
      (h = %MdH{}, {_, acc}) -> {Regex.match?(section, h.content), acc};
      (_, {false, acc}) -> {false, acc};
      (l, {true, acc}) -> {true, [scavenge_links(l) | acc]}
    end
    {_, block} = block
    List.flatten(block)
  end

  defp scavenge_links(%MdL{blocks: list}) do
    for item <- list, do: scavenge_links(item)
  end
  defp scavenge_links(%MdLI{blocks: list}) do
    for item <- list, do: scavenge_links(item)
  end
  defp scavenge_links(%MdP{lines: lines}) do
    links = for line <- lines, do: scavenge_links(line)
    Enum.filter(links, fn x -> !is_nil(x) end)
  end
  defp scavenge_links(line) do
    case Regex.run(~r<\[([^\]]*)\]\(https://github.com/([^()/#?]*)/([^()/#?]*)[^()]*\)>, line) do
      [_, label, user, repo | _] -> {label, "#{user}/#{repo}"}
      _ -> nil
    end
  end
end
