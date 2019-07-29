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
    |> Enum.map(&partial/1)
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
      {:call, __MODULE__, :add_book_new, [isbn(), title(), author(), 1, 1]},
      {:call, __MODULE__, :add_copy_new, [isbn()]},
      {:call, __MODULE__, :borrow_copy_unknown, [isbn()]},
      {:call, __MODULE__, :find_book_by_author_unknown, [author()]},
      {:call, __MODULE__, :find_book_by_isbn_unknown, [isbn()]},
      {:call, __MODULE__, :find_book_by_title_unknown, [title()]},
      {:call, __MODULE__, :return_copy_unknown, [isbn()]}
    ]

    relies_on_state =
      if map_size(state) == 0 do
        []
      else
        [
          {:call, __MODULE__, :add_book_existing, [isbn(state), title(), author(), 1, 1]},
          {:call, __MODULE__, :add_copy_existing, [isbn(state)]},
          {:call, __MODULE__, :borrow_copy_avail, [isbn(state)]},
          {:call, __MODULE__, :borrow_copy_unavail, [isbn(state)]},
          {:call, __MODULE__, :return_copy_existing, [isbn(state)]},
          {:call, __MODULE__, :return_copy_full, [isbn(state)]},
          {:call, __MODULE__, :find_book_by_isbn_exists, [isbn(state)]},
          {:call, __MODULE__, :find_book_by_author_matching, [author(state)]},
          {:call, __MODULE__, :find_book_by_title_matching, [title(state)]}
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

  def precondition(s, {:call, _, :borrow_copy_avail, [isbn]}) do
    case Map.fetch(s, isbn) do
      {:ok, {_, _, _, _, n}} when n > 0 -> true
      _ -> false
    end
  end

  def precondition(s, {:call, _, :borrow_copy_unavail, [isbn]}) do
    case Map.fetch(s, isbn) do
      {:ok, {_, _, _, _, 0}} -> true
      _ -> false
    end
  end

  def precondition(s, {:call, _, :borrow_copy_unknown, [isbn]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :find_book_by_author_matching, [auth]}),
    do: like_author(s, auth)

  def precondition(s, {:call, _, :find_book_by_author_unknown, [auth]}),
    do: not like_author(s, auth)

  def precondition(s, {:call, _, :find_book_by_isbn_unknown, [isbn]}),
    do: not has_isbn(s, isbn)

  def precondition(s, {:call, _, :find_book_by_title_matching, [title]}),
    do: like_title(s, title)

  def precondition(s, {:call, _, :find_book_by_title_unknown, [title]}),
    do: not like_title(s, title)

  def precondition(s, {:call, _, :return_copy_existing, [isbn]}) do
    case Map.fetch(s, isbn) do
      {:ok, {_, _, _, owned, avail}} when owned > avail and owned > 0 -> true
      _ -> false
    end
  end

  def precondition(s, {:call, _, :return_copy_full, [isbn]}) do
    case Map.fetch(s, isbn) do
      {:ok, {_, _, _, n, n}} when n > 0 -> true
      _ -> false
    end
  end

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
    do: book_equal(book, Map.get(state, isbn, nil))

  def postcondition(state, {_, _, :find_book_by_author_matching, [auth]}, {:ok, books}) do
    expected_books =
      state
      |> Map.values()
      |> Stream.filter(&(&1 |> elem(2) |> contains?(auth)))
      |> Enum.sort()

    books
    |> Enum.sort()
    |> books_equal(expected_books)
  end

  def postcondition(_, {_, _, :find_book_by_author_unknown, _}, {:ok, []}), do: true

  def postcondition(state, {_, _, :find_book_by_title_matching, [title]}, {:ok, books}) do
    expected_books =
      state
      |> Map.values()
      |> Stream.filter(&(&1 |> elem(1) |> contains?(title)))
      |> Enum.sort()

    books
    |> Enum.sort()
    |> books_equal(expected_books)
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

  defp books_equal([], []) do
    true
  end

  defp books_equal([a | as], [b | bs]) do
    book_equal(a, b) && books_equal(as, bs)
  end

  defp books_equal(_, _) do
    false
  end

  defp book_equal(
         {isbn_a, title_a, author_a, owned_a, avail_a},
         {isbn_b, title_b, author_b, owned_b, avail_b}
       ) do
    {isbn_a, owned_a, avail_a} == {isbn_b, owned_b, avail_b} &&
      String.equivalent?(
        IO.chardata_to_string(title_a),
        IO.chardata_to_string(title_b)
      ) &&
      String.equivalent?(
        IO.chardata_to_string(author_a),
        IO.chardata_to_string(author_b)
      )
  end

  defp book_equal(_, _), do: false

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

  ###
  ### Test shims
  ###
  def add_book_existing(isbn, title, author, owned, avail) do
    Bookstore.DB.add_book(isbn, title, author, owned, avail)
  end

  def add_book_new(isbn, title, author, owned, avail) do
    Bookstore.DB.add_book(isbn, title, author, owned, avail)
  end

  def add_copy_existing(isbn), do: Bookstore.DB.add_copy(isbn)
  def add_copy_new(isbn), do: Bookstore.DB.add_copy(isbn)

  def borrow_copy_avail(isbn), do: Bookstore.DB.borrow_copy(isbn)
  def borrow_copy_unavail(isbn), do: Bookstore.DB.borrow_copy(isbn)
  def borrow_copy_unknown(isbn), do: Bookstore.DB.borrow_copy(isbn)

  def return_copy_full(isbn), do: Bookstore.DB.return_copy(isbn)
  def return_copy_existing(isbn), do: Bookstore.DB.return_copy(isbn)
  def return_copy_unknown(isbn), do: Bookstore.DB.return_copy(isbn)

  def find_book_by_isbn_exists(isbn), do: Bookstore.DB.find_book_by_isbn(isbn)
  def find_book_by_isbn_unknown(isbn), do: Bookstore.DB.find_book_by_isbn(isbn)

  def find_book_by_author_matching(author), do: Bookstore.DB.find_book_by_author(author)
  def find_book_by_author_unknown(author), do: Bookstore.DB.find_book_by_author(author)

  def find_book_by_title_matching(title), do: Bookstore.DB.find_book_by_title(title)
  def find_book_by_title_unknown(title), do: Bookstore.DB.find_book_by_title(title)
end
