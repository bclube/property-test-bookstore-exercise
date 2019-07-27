defmodule BookstoreTest do
  use ExUnit.Case
  use PropCheck
  use PropCheck.StateM
  doctest Bookstore

  ###
  ### Properties
  ###
  property "bookstore stateful operations", [:verbose] do
    forall cmds <- commands(__MODULE__) do
      {:ok, apps} = Application.ensure_all_started(:bookstore)
      Bookstore.DB.setup()
      {history, state, result} = run_commands(__MODULE__, cmds)
      Bookstore.DB.teardown()
      for app <- apps, do: Application.stop(app)

      (result == :ok)
      |> aggregate(command_names(cmds))
      |> when_fail(
        IO.puts("""
        History: #{inspect(history)}
        State: #{inspect(state)}
        Result: #{inspect(state)}
        """)
      )
    end
  end

  ###
  ### Generators
  ###
  def title(), do: friendly_unicode()

  def title(state) do
    state
    |> Map.values()
    |> Stream.map(&elem(&1, 1))
    |> Stream.map(&partial/1)
    |> Enum.map(&String.to_charlist/1)
    |> elements()
  end

  def author(), do: friendly_unicode()

  def author(state) do
    state
    |> Map.values()
    |> Stream.map(&elem(&1, 2))
    |> Enum.map(&partial/1)
    |> elements()
  end

  def friendly_unicode() do
    bad_chars = [<<0>>, "\\", "_", "%"]
    friendly_gen =
      such_that s <- utf8(),
        when: (not contains_any?(s, bad_chars))
        && String.length(s) < 256

    let x <- friendly_gen do
      elements([x, String.to_charlist(x)])
    end
  end

  def isbn() do
    let isbn <- [
          oneof(['978', '979']),
          let(x <- range(0, 9999), do: to_charlist(x)),
          let(x <- range(0, 9999), do: to_charlist(x)),
          let(x <- range(0, 999), do: to_charlist(x)),
          frequency([
            {10, [range(?0, ?9)]},
            {1, 'X'}
          ])
        ] do
      to_string(Enum.join(isbn, "-"))
    end
  end

  def isbn(state) do
    state
    |> Map.keys()
    |> elements()
  end

  defp partial(string) do
    string = IO.chardata_to_string(string)
    l = String.length(string)

    let {start, len} <- {range(0, l), non_neg_integer()} do
      String.slice(string, start, len)
    end
  end

  ###
  ### Callbacks
  ###
  @impl true
  def initial_state(), do: %{}

  @impl true
  def command(state) do
    always_possible = [
      {:call, BookShim, :add_book_new, [isbn(), title(), author(), 1, 1]},
      {:call, BookShim, :add_copy_new, [isbn()]},
      {:call, BookShim, :borrow_copy_unknown, [isbn()]},
      {:call, BookShim, :find_book_by_author_unknown, [author()]},
      {:call, BookShim, :find_book_by_isbn_unknown, [isbn()]},
      {:call, BookShim, :find_book_by_title_unknown, [title()]},
      {:call, BookShim, :return_copy_unknown, [isbn()]}
    ]

    relies_on_state =
      if map_size(state) == 0 do
        []
      else
        [
          {:call, BookShim, :add_book_existing, [isbn(state), title(), author(), 1, 1]},
          {:call, BookShim, :add_copy_existing, [isbn(state)]},
          {:call, BookShim, :borrow_copy_avail, [isbn(state)]},
          {:call, Bookshim, :borrow_copy_unavail, [isbn(state)]},
          {:call, BookShim, :return_copy_existing, [isbn(state)]},
          {:call, BookShim, :return_copy_full, [isbn(state)]},
          {:call, BookShim, :find_book_by_isbn_exists, [isbn(state)]},
          {:call, BookShim, :find_book_by_author_matching, [author(state)]},
          {:call, BookShim, :find_book_by_title_matching, [title(state)]}
        ]
      end

    oneof(always_possible ++ relies_on_state)
  end

  @impl true
  # Picks whether a command should be valid under the current state.
  # - all the unknown calls
  def precondition(s, {:call, _, :add_book_new, [isbn | _]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :add_copy_new, [isbn]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :borrow_copy_unknown, [isbn]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :find_book_by_author_matching, [auth]}),
    do: like_author(s, auth)

  def precondition(s, {:call, _, :find_book_by_author_unknown, [auth]}),
    do: not has_isbn(s, auth)

  def precondition(s, {:call, _, :find_book_by_isbn_unknown, [isbn]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :find_book_by_title_matching, [title]}),
    do: like_title(s, title)

  def precondition(s, {:call, _, :find_book_by_title_unknown, [title]}),
    do: not has_isbn(s, title)

  def precondition(s, {:call, _, :return_copy_unknown, [isbn]}),
    do: not has_isbn(s, isbn)

  # - all calls with known ISBNs
  def precondition(s, {:call, _mod, _fun, [isbn | _]}),
    do: has_isbn(s, isbn)

  @impl true
  def postcondition(_, {_, _, :add_book_existing, _}, {:error, _}), do: true
  def postcondition(_, {_, _, :add_book_new, _}, :ok), do: true
  def postcondition(_, {_, _, :add_copy_existing, _}, :ok), do: true
  def postcondition(_, {_, _, :add_copy_new, _}, {:error, :not_found}), do: true
  def postcondition(_, {_, _, :borrow_copy_avail, _}, :ok), do: true
  def postcondition(_, {_, _, :borrow_copy_unavail, _}, {:error, :unavailable}), do: true
  def postcondition(_, {_, _, :borrow_copy_unknown, _}, {:error, :not_found}), do: true
  def postcondition(_, {_, _, :find_book_by_isbn_unknown, _}, {:ok, []}), do: true
  def postcondition(_, {_, _, :return_copy_existing, _}, :ok), do: true
  def postcondition(_, {_, _, :return_copy_full, _}, {:error, _}), do: true
  def postcondition(_, {_, _, :return_copy_unknown, _}, {:error, :not_found}), do: true

  def postcondition(state, {_, _, :find_book_by_isbn_exists, [isbn]}, {:ok, [book]}),
    do: book == Map.fetch!(state, isbn)

  def postcondition(state, {_, _, :find_book_by_author_matching, [auth]}, {:ok, books}) do
    expected_books =
      state
      |> Map.keys()
      |> Stream.map(&elem(&1, 2))
      |> Stream.filter(&contains?(&1, auth))
      |> MapSet.new()

    Enum.all?(books, &Map.member?(expected_books, &1))
  end

  def postcondition(_, {_, _, :find_book_by_author_unknown, _}, {:ok, []}), do: true

  def postcondition(state, {_, _, :find_book_by_title_matching, [title]}, {:ok, books}) do
    expected_books =
      state
      |> Map.keys()
      |> Stream.map(&elem(&1, 1))
      |> Stream.filter(&contains?(&1, title))
      |> MapSet.new()

    Enum.all?(books, &Map.member?(expected_books, &1))
  end

  def postcondition(_, {_, _, :find_book_by_title_unknown, _}, {:ok, []}), do: true

  def postcondition(_state, {:call, mod, fun, args}, res) do
    IO.puts("""
    Non-matching postcondition:
    ** Module: #{inspect(mod)}
    ** Function: #{inspect(fun)}
    ** Args: #{inspect(args)}
    -> Result: #{inspect(res)}
    """)

    false
  end

  @impl true
  def next_state(state, _, {:call, _, :add_book_new, [isbn, title, author, owned, avail]}) do
    Map.put(state, isbn, {isbn, title, author, owned, avail})
  end

  def next_state(state, _, {:call, _, :add_copy_existing, [isbn]}) do
    {^isbn, title, author, owned, avail} = state[isbn]
    Map.put(state, isbn, {isbn, title, author, owned + 1, avail + 1})
  end

  def next_state(state, _, {:call, _, :borrow_copy_avail, [isbn]}) do
    {^isbn, title, author, owned, avail} = state[isbn]
    Map.put(state, isbn, {isbn, title, author, owned, avail - 1})
  end

  def next_state(state, _, {:call, _, :return_copy_existing, [isbn]}) do
    {^isbn, title, author, owned, avail} = state[isbn]
    Map.put(state, isbn, {isbn, title, author, owned, avail + 1})
  end

  def next_state(state, _res, {:call, _mod, _fun, _args}), do: state

  ###
  ### Helpers
  ###
  def has_isbn(map, isbn), do: Map.has_key?(map, isbn)

  def like_author(map, auth) do
    map
    |> Map.values()
    |> Stream.map(&elem(&1, 2))
    |> Enum.any?(&contains?(&1, auth))
  end

  def like_title(map, title) do
    map
    |> Map.values()
    |> Stream.map(&elem(&1, 1))
    |> Enum.any?(&contains?(&1, title))
  end

  defp contains?(string_or_chars_full, string_or_char_pattern) do
    string = IO.chardata_to_string(string_or_chars_full)
    pattern = IO.chardata_to_string(string_or_char_pattern)
    String.contains?(string, pattern)
  end

  defp contains_any?(string_or_chars, patterns) when is_list(patterns) do
    string = IO.chardata_to_string(string_or_chars)
    patterns = for p <- patterns, do: IO.chardata_to_string(p)
    String.contains?(string, patterns)
  end
end
