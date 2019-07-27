defmodule BookShim do
  alias Bookstore.DB

  def add_book_existing(isbn, title, author, owned, avail) do
    DB.add_book(isbn, title, author, owned, avail)
  end

  def add_book_new(isbn, title, author, owned, avail) do
    DB.add_book(isbn, title, author, owned, avail)
  end

  def add_copy_existing(isbn), do: DB.add_copy(isbn)
  def add_copy_new(isbn), do: DB.add_copy(isbn)

  def borrow_copy_avail(isbn), do: DB.borrow_copy(isbn)
  def borrow_copy_unavail(isbn), do: DB.borrow_copy(isbn)
  def borrow_copy_unknown(isbn), do: DB.borrow_copy(isbn)

  def return_copy_full(isbn), do: DB.return_copy(isbn)
  def return_copy_existing(isbn), do: DB.return_copy(isbn)
  def return_copy_unknown(isbn), do: DB.return_copy(isbn)

  def find_book_by_isbn_exists(isbn), do: DB.find_book_by_isbn(isbn)
  def find_book_by_isbn_unknown(isbn), do: DB.find_book_by_isbn(isbn)

  def find_book_by_author_matching(author), do: DB.find_book_by_author(author)
  def find_book_by_author_unknown(author), do: DB.find_book_by_author(author)

  def find_book_by_title_matching(title), do: DB.find_book_by_title(title)
  def find_book_by_title_unknown(title), do: DB.find_book_by_title(title)
end
