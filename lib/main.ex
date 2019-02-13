defmodule NotQuiteAwesome.Main do
  @help """
  nqa [-h] [--help] [--dry-run] REPOSITORY SECTION
  
  NotQuiteAwesome - a parser and sorter of awesome lists on github
                    (https://github.com/sindresorhus/awesome)
					
  At this time it can only sort one section of a list by the number of
  stars (highest first). The SECTION parameter is a regular expression.
  
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

	with(
	  {:ok, repo, section, flags} <- getopts(argv),
	  {:ok, section} <- section_regexp(section),
	  {:ok, readme} <- stage("Fetching readme...", do: fetch_readme(repo))
	) do
	  repos = stage("Looking for links...", do: find_repo_links(readme, section))
	  unless flags[:dry_run] do
		sorted_repos = stage("Sniffing repos...", do: sort_by_stars(repos))
		format(sorted_repos)
	  else
		dry_run(repos)
	  end
	else
	  :help ->
		IO.write(:stderr, @help)
	  {:error, msg} ->
		IO.puts(:stderr, msg)
	end
  end

  defp section_regexp(src) do
	case Regex.compile(src) do
	  ok = {:ok, _re} ->
		ok
	  {:error, {msg, _}} ->
		{:error, "Error compiling regular expression: #{msg}"}
	end
  end

  defp getopts(argv) do
	cfg = [
	  strict: [dry_run: :boolean, help: :boolean],
	  aliases: [h: :help]
	]

	{flags, argv, invalid} = OptionParser.parse(argv, cfg)

	unless flags[:help] do
	  case {argv, invalid} do
		{[repo, section], []} ->
		  {:ok, repo, section, flags}
		_ ->
		  {:error, "Error: invalid arguments; see --help"}
	  end
	else
	  :help
	end
  end

  def dry_run(repos) do
	lines = for {label, repo} <- repos do
		"\n#{label}: https://github.com/#{repo}"
	end

	IO.puts :stderr, [
	  "Scanning the following repositories:\n",
	  lines
	]
  end

  defp format(repos) do
	Enum.each repos, fn {label, url, stars} ->
	  IO.puts("#{label} (#{url}): #{stars}")
	end
	if Enum.find(repos, fn {_, _, :error} -> true; _ -> false end) do
	  IO.puts(:stderr, "WARNING: I were unable to access some repositories (probably due to github API rate limit).")
	end
  end

  defp sort_by_stars(repos) do
	tasks = for {_, repo} <- repos do
	  Task.async(fn -> fetch_repo_stars(repo) end)
	end
	Enum.zip(repos, tasks)
	|> Enum.map(fn {{label, url}, stars} ->
	  {label, url, Task.await(stars)}
	end)
	|> Enum.sort(fn {_, _, a}, {_, _, b} -> a >= b end)
  end

  defp fetch_repo_stars(repo) do
	try do
	  Map.get(fetch_repo_info(repo), "stargazers_count")
	catch
	  %HTTP.RequestError{} ->
		:error
	end
  end

  defp fetch_repo_info(repo) do
	HTTP.get('https://api.github.com/repos/' ++ to_charlist(repo))
	|> to_string()
	|> JSON.decode!()
  end

  defp fetch_readme(repo) do
	variants = ["README.md", "readme.md", "README.MD"]
	try do
	  Enum.each(variants, fn v -> try_readme(repo, v) end)
	catch
	  r = {:ok, _tree} -> r
	else
	  _ -> {:error, "No README file found"}
	end
  end

  defp try_readme(repo, variant) do
	try do
	  HTTP.get('https://raw.githubusercontent.com/#{repo}/master/#{variant}')
	  |> to_string()
	  |> Earmark.parse(%Earmark.Options{smartypants: false})
	  |> fn {tree, _} -> {:ok, tree} end.()
	catch
	  %HTTP.RequestError{} -> :ignore
	else
	  result -> throw result
	end
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
