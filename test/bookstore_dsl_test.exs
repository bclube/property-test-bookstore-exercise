defmodule BookstoreDslTest do
  use ExUnit.Case
  use PropCheck
  use PropCheck.StateM.DSL

  ###
  ### Properties
  ###
  property "bookstore stateful operations", [:verbose] do
    forall cmds <- commands(__MODULE__) do
      {:ok, apps} = Application.ensure_all_started(:bookstore)
      Bookstore.DB.setup()
      events = run_commands(cmds)
      Bookstore.DB.teardown()
      for app <- apps, do: Application.stop(app)

      (events.result == :ok)
      |> when_fail(
        IO.puts("""
        Commands: #{inspect(command_names(cmds), pretty: true)}
        History: #{inspect(events.history, pretty: true)}
        State: #{inspect(events.state, pretty: true)}
        Result: #{inspect(events.result, pretty: true)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  ###
  ### Callbacks
  ###
  def initial_state(), do: %{}

  def weight(state) do
    if map_size(state) != 0 do
      [
        add_book_existing: 1,
        add_book_new: 1,
        add_copy_existing: 1,
        add_copy_new: 1,
        borrow_copy_avail: 1,
        borrow_copy_unavail: 1,
        borrow_copy_unknown: 1,
        find_book_by_author_matching: 1,
        find_book_by_author_unknown: 1,
        find_book_by_isbn_exists: 1,
        find_book_by_isbn_unknown: 1,
        find_book_by_title_matching: 1,
        find_book_by_title_unknown: 1,
        return_copy_existing: 1,
        return_copy_full: 1,
        return_copy_unknown: 1
      ]
    else
      [
        add_book_new: 1,
        add_copy_new: 1,
        borrow_copy_unknown: 1,
        find_book_by_author_unknown: 1,
        find_book_by_isbn_unknown: 1,
        find_book_by_title_unknown: 1,
        return_copy_unknown: 1
      ]
    end
  end

  ###
  ### Commands
  ###
  defcommand :add_book_existing do
    def impl(isbn, title, author, owned, avail),
      do: Bookstore.DB.add_book(isbn, title, author, owned, avail)

    def args(state), do: [isbn(state), title(), author(), 1, 1]
    def pre(state, [isbn | _]), do: has_isbn(state, isbn)

    def post(_state, _args, call_result), do: match?({:error, _}, call_result)
  end

  defcommand :add_book_new do
    def impl(isbn, title, author, owned, avail),
      do: Bookstore.DB.add_book(isbn, title, author, owned, avail)

    def args(_state), do: [isbn(), title(), author(), 1, 1]
    def pre(state, [isbn | _]), do: not has_isbn(state, isbn)

    def next(state, [isbn, title, author, owned, avail], _call_result),
      do: Map.put(state, isbn, {isbn, title, author, owned, avail})

    def post(_state, _args, call_result), do: call_result == :ok
  end

  defcommand :add_copy_new do
    def impl(isbn), do: Bookstore.DB.add_copy(isbn)
    def args(_state), do: [isbn()]
    def pre(state, [isbn]), do: not has_isbn(state, isbn)
    def post(_state, _args, call_result), do: call_result == {:error, :not_found}
  end

  defcommand :add_copy_existing do
    def impl(isbn), do: Bookstore.DB.add_copy(isbn)
    def args(state), do: [isbn(state)]
    def pre(state, [isbn]), do: has_isbn(state, isbn)

    def next(state, [isbn], _call_result) do
      Map.update!(state, isbn, fn {^isbn, title, author, owned, avail} ->
        {isbn, title, author, owned + 1, avail + 1}
      end)
    end

    def post(_state, _args, call_result), do: call_result == :ok
  end

  defcommand :borrow_copy_avail do
    def impl(isbn), do: Bookstore.DB.borrow_copy(isbn)
    def args(state), do: [isbn(state)]

    def pre(state, [isbn]) do
      case Map.fetch(state, isbn) do
        {:ok, {_, _, _, _, avail}} -> avail > 0
        _ -> false
      end
    end

    def next(state, [isbn], _call_result) do
      Map.update!(state, isbn, fn {^isbn, title, author, owned, avail} ->
        {isbn, title, author, owned, avail - 1}
      end)
    end

    def post(_state, _args, call_result), do: call_result == :ok
  end

  defcommand :borrow_copy_unavail do
    def impl(isbn), do: Bookstore.DB.borrow_copy(isbn)
    def args(state), do: [isbn(state)]

    def pre(state, [isbn]) do
      case Map.fetch(state, isbn) do
        {:ok, {_, _, _, _, avail}} -> avail < 1
        _ -> false
      end
    end

    def post(_state, _args, call_result), do: call_result == {:error, :unavailable}
  end

  defcommand :borrow_copy_unknown do
    def impl(isbn), do: Bookstore.DB.borrow_copy(isbn)
    def args(_state), do: [isbn()]
    def pre(state, [isbn]), do: not has_isbn(state, isbn)
    def post(_state, _args, call_result), do: call_result == {:error, :not_found}
  end

  defcommand :find_book_by_author_matching do
    def impl(auth), do: Bookstore.DB.find_book_by_author(auth)
    def args(state), do: [author(state)]
    def pre(state, [auth]), do: like_author(state, auth)

    def post(state, [auth], {:ok, books}) do
      books
      |> Enum.sort()
      |> books_equal(
        state
        |> Map.values()
        |> Stream.filter(&(&1 |> elem(2) |> contains?(auth)))
        |> Enum.sort()
      )
    end

    def post(_state, _args, _call_result), do: false
  end

  defcommand :find_book_by_author_unknown do
    def impl(auth), do: Bookstore.DB.find_book_by_author(auth)
    def args(_state), do: [author()]
    def pre(state, [auth]), do: not like_author(state, auth)
    def post(_state, _args, call_result), do: call_result == {:ok, []}
  end

  defcommand :find_book_by_isbn_exists do
    def impl(isbn), do: Bookstore.DB.find_book_by_isbn(isbn)
    def args(state), do: [isbn(state)]
    def pre(state, [isbn]), do: has_isbn(state, isbn)

    def post(state, [isbn], {:ok, [book]}),
      do: state |> Map.get(isbn, nil) |> book_equal(book)

    def post(_state, _args, _result), do: false
  end

  defcommand :find_book_by_isbn_unknown do
    def impl(isbn), do: Bookstore.DB.find_book_by_isbn(isbn)
    def args(_state), do: [isbn()]
    def pre(state, [isbn]), do: not has_isbn(state, isbn)
    def post(_state, _args, result), do: match?({:ok, []}, result)
  end

  defcommand :find_book_by_title_matching do
    def impl(title_string), do: Bookstore.DB.find_book_by_title(title_string)
    def args(state), do: [title(state)]
    def pre(state, [title_string]), do: like_title(state, title_string)

    def post(state, [title_string], {:ok, books}) do
      books
      |> Enum.sort()
      |> books_equal(
        state
        |> Map.values()
        |> Stream.filter(&(&1 |> elem(1) |> contains?(title_string)))
        |> Enum.sort()
      )
    end

    def post(_state, _args, _result), do: false
  end

  defcommand :find_book_by_title_unknown do
    def impl(title_string), do: Bookstore.DB.find_book_by_title(title_string)
    def args(_state), do: [title()]
    def pre(state, [title_string]), do: not like_title(state, title_string)
    def post(_state, _args, result), do: match?({:ok, []}, result)
  end

  defcommand :return_copy_existing do
    def impl(isbn), do: Bookstore.DB.return_copy(isbn)
    def args(state), do: [isbn(state)]

    def pre(state, [isbn]) do
      case Map.fetch(state, isbn) do
        {:ok, {_, _, _, owned, avail}} -> owned > avail
        _ -> false
      end
    end

    def next(state, [isbn], _call_result) do
      Map.update!(state, isbn, fn {^isbn, title, author, owned, avail} ->
        {isbn, title, author, owned, avail + 1}
      end)
    end

    def post(_state, _args, result), do: result == :ok
  end

  defcommand :return_copy_full do
    def impl(isbn), do: Bookstore.DB.return_copy(isbn)
    def args(state), do: [isbn(state)]

    def pre(state, [isbn]) do
      case Map.fetch(state, isbn) do
        {:ok, {_, _, _, owned, avail}} -> owned == avail
        _ -> false
      end
    end

    def post(_state, _args, result), do: match?({:error, _}, result)
  end

  defcommand :return_copy_unknown do
    def impl(isbn), do: Bookstore.DB.return_copy(isbn)
    def args(_state), do: [isbn()]
    def pre(state, [isbn]), do: not has_isbn(state, isbn)
    def post(_state, _args, result), do: result == {:error, :not_found}
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
      such_that(
        s <- utf8(255),
        when: not contains_any?(s, bad_chars)
      )

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
end
